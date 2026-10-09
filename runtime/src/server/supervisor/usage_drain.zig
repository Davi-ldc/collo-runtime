//! The usage drain: moves the usage records each worker appends to the ring
//! on its page into the usage log, writes the floor record for a request
//! whose worker could not account for it, and settles each ended request in
//! its worker's request table.
//!
//! A worker writes its records into memory it controls, so the drain keeps a
//! record only when the server's own state vouches for it. The record must
//! name a request of the request table of the worker whose ring held it, one
//! whose record is still expected (`RequestTable.expected`), and it is
//! written under that table's request id, stamped with the identity the
//! server holds for the worker and the pattern of the route the table
//! recorded for the request (`requestIdentity`), never with the identity
//! fields the worker wrote. Any other record is counted in
//! `Counters.records_rejected` and dropped. A worker therefore cannot choose
//! whose record its measurements enter, nor record a request twice or a
//! request it was never dispatched.
//!
//! A worker's ring is drained under its `metrics_mutex`, the only thing that
//! serializes two drains of the same worker: the exactly-once filter, the
//! table checks, the identity search and the cursor's prefix advance are
//! sound only while it is held, and every drain checks under it that the
//! worker's page is still mapped (`Record.page_mapped`), which the final
//! drain clears before the reaper unmaps it. The usage log's and the request
//! table's locks nest inside `metrics_mutex`, and nothing here takes a pool's
//! mutex. The sink's `flush_mutex` is never taken under `metrics_mutex`: a
//! drain that writes the usage stream out lets go of it first.
//!
//! The drain reads the ring through the server's own cursor in the worker's
//! page view (`RecordCursor` in `common/worker_state/page/snapshots.zig`):
//! each pass loads the worker's head once, copies the records it covers once
//! each, and moves the cursor past those it consumed. A head no append can
//! produce, behind the cursor or more than a ring past it, fails the ring
//! (`Record.usage_ring_failed`): no drain reads it again, so a request the
//! server ends on that worker gets a floor, and the metrics thread takes the
//! worker out of service (`server/ingress/analytics_drain.zig`). A floor
//! takes what the worker measured from one copy of its request's live slot
//! (`LiveSlotSnapshot`), and the death classification reads the lifecycle
//! header once (`LifecycleSnapshot`).
//!
//! Exactly once: the drain skips a worker record for an attempt the server
//! already synthesized (`UsageLog.synthesisState`), the request table refuses
//! a worker record while the floor of its request is being written, and
//! synthesis writes no floor for a request whose worker record a drain
//! already settled (`RequestTable.usageRecorded`).
//!
//! A full usage stream fails no caller and holds up no request. A drain on a
//! thread that may block (`drainWorkerFlushing`: the metrics, reaper and
//! exiting threads) keeps a batch the stream has no room for in the ring,
//! writes the stream out and offers the batch again, and drops only what a
//! write-out leaves no room for; a lane's drain (`drainWorker`) drops such a
//! batch at once. A dropped batch is counted (`UsageLog.append`), and the
//! drain still advances the ring past it and marks its requests' records as
//! settled in the request table, so none of them waits in `awaiting_record`
//! for a record the ring no longer holds and synthesis writes no floor over
//! one it dropped. Synthesis runs on the lane that settles the request
//! (`settleRequest`); a floor that finds no room even in the synthesis
//! reserve is dropped and counted the same way, and the request's entry then
//! keeps expecting the worker's record
//! (`SynthesisOutcome.awaits_worker_record`), the one record it may still
//! get.

const std = @import("std");
const process = @import("collo_os").process;
const worker_shared_page = @import("collo_worker_state").page;
const worker_metrics_state = @import("collo_worker_state").metrics;
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const analytics = @import("collo_server_analytics");
const usage = analytics.usage;

const accounting = @import("accounting/root.zig");
const cgroup = @import("collo_cgroup");
const worker_table = @import("worker_table.zig");
const usage_log = @import("usage_log.zig");
const request_table = @import("request_table.zig");

const WorkerRecord = worker_table.Record;
const CompletedRecord = worker_shared_page.CompletedRecord;
const UsageKey = accounting.usage.UsageKey;

const batch_len = usage_log.batch_records_max;

/// What the drain reaches, assembled per call by `Supervisor.usageDrain()`;
/// the supervisor stays the owner of all of it. Naming these lets a test
/// drive the drain with four things it owns instead of forging a supervisor.
/// The identities, start times, marks and pending records the usage rules
/// need live on each worker record (`Record.requests`).
pub const UsageDrain = struct {
    allocator: std.mem.Allocator,
    usage: *usage_log.UsageLog,
    /// Borrowed; the route patterns usage records carry.
    routes: *const routes_mod.Routes,
    counters: *Counters,
};

/// What the drains and the floors count beside the usage stream's own
/// losses (`Sink` stats). Every thread that drains or settles adds to them.
///
/// FIXME: outside tests, nothing reads these counters; no exporter publishes
/// them yet.
pub const Counters = struct {
    /// Worker-written usage records the drains refused because the worker's
    /// request table expects no record for their request id: a request never
    /// dispatched to that worker, one already recorded, one whose floor the
    /// server is writing, or one whose entry was evicted after the worker
    /// published its completion without the record (`request_table.zig`).
    /// Each was dropped, and each means the worker broke the protocol.
    records_rejected: std.atomic.Value(u64) = .init(0),
    /// Ring drains that stopped early because the record at the head belongs
    /// to an identity another thread is synthesizing for. The ring advances by
    /// a contiguous prefix, so one blocked record holds back every record
    /// behind it, and the worker stops itself if its ring fills. Growth here
    /// is the only warning before that, so it reads as a latency signal, not
    /// an error.
    drains_blocked: std.atomic.Value(u64) = .init(0),
    /// Floor records written after the deep ring scan came back empty. This
    /// is the path where a wrong answer records a request the worker had
    /// already reported: the scan is the last thing between a dying worker and
    /// a second record for the same request. Non-zero is normal.
    floors_after_deep_scan: std.atomic.Value(u64) = .init(0),
    /// Floors not written because the exactly-once index could not grow. The
    /// request's entry keeps expecting the worker's record, its only record
    /// from then on.
    floors_unindexed: std.atomic.Value(u64) = .init(0),
};

/// How a request ended, as the settle of its usage needs to know it.
pub const SettleOutcome = union(enum) {
    /// The worker published the request's completion, after it appended the
    /// request's usage record: the entry waits for the drain that writes it.
    completed,
    /// The server ended the request without a completion from the worker. It
    /// writes the request's floor record, unless the worker already wrote its
    /// own (`synthesizeFinalAccountingForLifecycle`).
    floor: Floor,
    /// The request never reached the worker: no record is written or kept.
    abandoned,
};

/// What the floor record of a request the server ended says about its end.
pub const Floor = struct {
    status: worker_shared_page.CompletedStatus,
    /// The label of the worker fault that ended the request
    /// (`WorkerFaultReason.label` in `server/ingress/fault.zig`), a static
    /// string; "" when none did.
    worker_fault: []const u8 = "",
};

const DrainResult = struct {
    written: usize = 0,
    /// Records the ring moved past: written, dropped, refused or skipped.
    advanced: usize = 0,
    /// `OnFull.hold` only: the drain stopped at a batch the usage stream had
    /// no room for, which stays in the ring.
    held: bool = false,
    found: bool = false,
    /// The consume pass stopped at another thread's reservation and the deep
    /// scan answered the identity question instead. Reported so the caller can
    /// count the path where a wrong answer records a request twice.
    deep_scanned: bool = false,
};

/// Write-outs one `drainWorkerFlushing` may ask for. Each write-out short of
/// a stall lets at least one batch through, so this many cover a ring that
/// is full when the drain starts.
const write_outs_per_drain_max: usize = worker_shared_page.RECORD_RING_COUNT / batch_len;

/// Drains the worker of every record in `records` on a thread that may write
/// the usage stream out (`drainWorkerFlushing`): the metrics thread each
/// tick, before it flushes the sink (`tick` in
/// `server/ingress/analytics_drain.zig`), and the exiting thread at shutdown.
/// A record whose page is not mapped is skipped under its lock. Once a
/// write-out leaves no room for a batch, the file is not taking records, and
/// the workers after it drain with drops (`drainWorker`), so such a file
/// costs one failed write a call rather than one a worker.
pub fn drainAll(ctx: UsageDrain, records: []WorkerRecord) void {
    var stream_stalled = false;
    for (records) |*worker| {
        if (stream_stalled) {
            _ = drainWorker(ctx, worker);
        } else {
            stream_stalled = !drainWorkerFlushing(ctx, worker);
        }
    }
}

/// Appends the records in `worker`'s ring to the usage log and returns how
/// many the usage stream took. A batch the stream has no room for is dropped
/// and counted, and the ring moves past every record it settles, those
/// included (`UsageLog.append`). For a thread that may not block on writing
/// the stream out, such as a lane; one that may calls `drainWorkerFlushing`.
pub fn drainWorker(ctx: UsageDrain, worker: *WorkerRecord) usize {
    return drainWorkerOnFull(ctx, worker, .drop).written;
}

/// Drains `worker` on a thread that may block on writing the usage stream
/// out: the metrics thread, the reaper and the exiting thread. A batch the
/// stream has no room for stays in the ring while this thread writes the
/// stream out (`Sink.flush`), outside `worker.metrics_mutex`, and is offered
/// again. A batch that finds no room right after a write-out means the file
/// is not taking records: it and every record behind it are dropped and
/// counted, so the ring still empties, and this returns false. Records the
/// worker keeps appending through `write_outs_per_drain_max` write-outs are
/// dropped the same way, since a caller such as `drainFinal` unmaps the page
/// next.
pub fn drainWorkerFlushing(ctx: UsageDrain, worker: *WorkerRecord) bool {
    var write_outs: usize = 0;
    while (write_outs <= write_outs_per_drain_max) : (write_outs += 1) {
        if (write_outs != 0)
            ctx.usage.sink.flush(process.monotonicNowNsOrZero());
        const result = drainWorkerOnFull(ctx, worker, .hold);
        if (!result.held)
            return true;
        if (write_outs != 0 and result.advanced == 0) {
            _ = drainWorker(ctx, worker);
            return false;
        }
    }
    _ = drainWorker(ctx, worker);
    return true;
}

/// The last drains of a worker that left its pool, before the reaper unmaps
/// its page (`Record.vacate`): the usage ring written out on this thread
/// (`drainWorkerFlushing`), then, under one hold of `worker.metrics_mutex`,
/// the dying console ring, the usage ring once more with drops, and the page
/// marked unmapped for every later drain. The exactly-once index then
/// forgets the worker, since no record can arrive from a page no drain
/// reads. The reaper calls it, and the exiting thread at teardown, after the
/// worker's exit (`Record.awaitExit`), so the rings hold their last records.
pub fn drainFinal(ctx: UsageDrain, worker: *WorkerRecord) void {
    _ = drainWorkerFlushing(ctx, worker);
    finalHold(ctx, worker);
    ctx.usage.forgetWorker(worker.id, worker.generation);
}

/// The part of `drainFinal` under `worker.metrics_mutex`.
fn finalHold(ctx: UsageDrain, worker: *WorkerRecord) void {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();
    if (!worker.page_mapped)
        return;
    // A ring that already failed is never read again
    // (`Record.log_ring_failed`).
    if (!worker.log_ring_failed) {
        if (worker.handle.metrics) |*view|
            analytics.logs.drainDyingRing(
                view,
                analytics.Identity.ofWorker(worker),
                &worker.log_drops_reported,
                ctx.usage.sink,
            );
    }
    _ = drainLocked(ctx, worker, null, .drop, "final drain");
    worker.page_mapped = false;
}

fn drainWorkerOnFull(ctx: UsageDrain, worker: *WorkerRecord, on_full: usage_log.OnFull) DrainResult {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();
    return drainLocked(ctx, worker, null, on_full, "drain");
}

/// Settles the usage of the request `request_id` that ended on `worker`, as
/// `outcome` says, and frees or parks its request table entry. The lane that
/// finishes the request calls it while it still holds the request's pool
/// slot, before `Pool.release`, which keeps the worker's page mapped for
/// the call. It takes only the worker's request table lock and, when it
/// drains or writes a floor, `worker.metrics_mutex`, and it never writes the
/// usage stream out. It never fails: a floor the exactly-once index cannot
/// take is counted (`Counters.floors_unindexed`), and the entry then keeps
/// expecting the worker's record.
pub fn settleRequest(
    ctx: UsageDrain,
    worker: *WorkerRecord,
    request_id: u64,
    outcome: SettleOutcome,
) void {
    switch (outcome) {
        .completed => settleTable(ctx, worker, request_id, true),
        .abandoned => worker.requests.remove(request_id),
        .floor => |floor| {
            const synthesis = synthesizeFinalAccountingForLifecycle(ctx, worker, request_id, floor) catch |err| switch (err) {
                error.OutOfMemory => blk: {
                    _ = ctx.counters.floors_unindexed.fetchAdd(1, .monotonic);
                    std.log.warn("usage floor not written for request_id={d} worker_id={d}: the exactly-once index could not grow", .{
                        request_id,
                        worker.id,
                    });
                    break :blk SynthesisOutcome.awaits_worker_record;
                },
            };
            settleTable(ctx, worker, request_id, synthesis.expectsWorkerRecord());
        },
    }
}

/// Settles `request_id`'s entry once the request ended and its slot is about
/// to be released (`RequestTable.settle`). With `expects_worker_record`, the
/// entry waits for the worker's own record: the worker published the
/// request's completion, and a worker appends the record before the
/// completion, or synthesis left that record expected
/// (`SynthesisOutcome.awaits_worker_record`).
///
/// When `request_table.awaiting_record_max` entries already wait, this drains
/// the worker first: an honest worker appended every awaited record before
/// its completion, so the drain settles them, written or dropped by a full
/// usage stream, and frees their entries. If the table is still full, the
/// worker published completions without their records: the oldest waiting
/// entry is evicted, and a record for that request that shows up later is
/// refused.
fn settleTable(
    ctx: UsageDrain,
    worker: *WorkerRecord,
    request_id: u64,
    expects_worker_record: bool,
) void {
    switch (worker.requests.settle(request_id, expects_worker_record)) {
        .freed, .awaiting_record => return,
        .awaiting_full => {},
    }
    _ = drainWorker(ctx, worker);
    switch (worker.requests.settle(request_id, expects_worker_record)) {
        .freed, .awaiting_record => return,
        .awaiting_full => {},
    }
    const evicted_request_id = worker.requests.settleEvictingOldest(request_id) orelse return;
    std.log.warn("usage record never arrived for request_id={d} worker_id={d}; its entry was evicted", .{
        evicted_request_id,
        worker.id,
    });
}

/// Outcome of claiming an identity for synthesis.
pub const SynthesisClaim = struct {
    reservation: usage_log.Reservation,
    /// The worker already authored a record for this request, still in its
    /// ring or already settled by a drain, written or dropped, so no floor
    /// may be written.
    worker_authored: bool,
    /// The answer came from the deep scan rather than from the consume pass,
    /// which is the path where a wrong answer records a request twice.
    deep_scanned: bool,
};

/// Claims `identity` for a synthesized record and answers, within the same
/// hold of `worker.metrics_mutex`, whether the worker already authored one.
///
/// No drain of this worker can run between the reservation and the answer. A
/// drain that comes after the reservation stops at the reserved record, which
/// blocks consumption, so the worker's record stays in the ring until the
/// claim resolves. A drain that finished before the reservation already
/// settled the worker's record, written or dropped, and marked it in the
/// worker's request table, which is why the table is asked before the ring
/// and again after the claim's own drain. A claim that finds no worker
/// record moves the request's entry to `synthesizing`, so a worker record
/// that shows up while the floor is written is refused whatever identity
/// fields it carries.
///
/// An inactive reservation means another caller owns this attempt, and the
/// caller writes nothing. A `worker_authored` claim is the caller's to roll
/// back, which releases a record still in the ring to the next drain.
pub fn claimSynthesisForLifecycle(
    ctx: UsageDrain,
    worker: *WorkerRecord,
    identity: worker_shared_page.LifecycleIdentity,
) error{OutOfMemory}!SynthesisClaim {
    worker.metrics_mutex.lock();
    defer worker.metrics_mutex.unlock();

    const reservation = try ctx.usage.reserveSynthesis(identity);
    if (!reservation.active)
        return .{ .reservation = reservation, .worker_authored = false, .deep_scanned = false };

    const request_id = identity.external_request_id;
    if (worker.requests.usageRecorded(request_id))
        return .{ .reservation = reservation, .worker_authored = true, .deep_scanned = false };
    const result = drainLocked(ctx, worker, identity, .drop, "find drain");
    // A record found in the ring counts only when the table would keep it;
    // otherwise the drain refuses it and the request would end with no
    // record at all.
    const worker_authored = worker.requests.usageRecorded(request_id) or
        (result.found and worker.requests.expected(request_id) != null);
    if (!worker_authored)
        worker.requests.beginSynthesis(request_id);
    return .{
        .reservation = reservation,
        .worker_authored = worker_authored,
        .deep_scanned = result.deep_scanned,
    };
}

/// `worker.metrics_mutex` must be held for the whole call. A worker whose
/// page is not mapped, or whose ring failed, has nothing to drain.
fn drainLocked(
    ctx: UsageDrain,
    worker: *WorkerRecord,
    target_identity: ?worker_shared_page.LifecycleIdentity,
    on_full: usage_log.OnFull,
    comptime warn_label: []const u8,
) DrainResult {
    if (!worker.page_mapped)
        return .{};
    if (worker.usage_ring_failed)
        return .{};
    const metrics = if (worker.handle.metrics) |*metrics|
        metrics
    else
        return .{};
    return drainRingLocked(ctx, worker, metrics, target_identity, on_full, warn_label);
}

/// The ring scan itself. Records are keyed by `worker`'s key, kept only when
/// `worker.requests`, the table of the worker the ring belongs to, vouches
/// for them, and stamped with the identity of the request the table
/// recorded; the table receives the marks of what was settled. With
/// `on_full` `.hold`, the scan stops at the first batch the usage stream has
/// no room for and leaves it in the ring. Such a stop leaves the rest of the
/// ring unsearched, so only a scan that looks for no identity may hold;
/// synthesis, the one caller that looks, scans with `.drop`.
fn drainRingLocked(
    ctx: UsageDrain,
    worker: *WorkerRecord,
    metrics: *worker_shared_page.WorkerWriterView,
    target_identity: ?worker_shared_page.LifecycleIdentity,
    on_full: usage_log.OnFull,
    comptime warn_label: []const u8,
) DrainResult {
    if (on_full == .hold)
        std.debug.assert(target_identity == null);
    const worker_key = worker.key();
    const clock = analytics.Clock.capture();
    var result = DrainResult{};
    const cursor = &metrics.host_cursors.records;
    var records: [batch_len]CompletedRecord = undefined;
    var appended: [batch_len]usage.UsageRecord = undefined;
    var appended_request_ids: [batch_len]u64 = undefined;
    var skipped_keys: [batch_len]UsageKey = undefined;
    var total_seen: usize = 0;
    // Counts only batches the ring advanced past, and is reported on every
    // exit.
    var total_rejected: usize = 0;
    defer {
        if (total_rejected != 0) {
            _ = ctx.counters.records_rejected.fetchAdd(total_rejected, .monotonic);
            std.log.warn("usage {s} refused {d} worker records for requests the server does not expect worker_id={d}", .{
                warn_label,
                total_rejected,
                worker_key.worker_id,
            });
        }
    }
    var stopped_on_reserved_synthesis = false;
    while (total_seen < worker_shared_page.RECORD_RING_COUNT) {
        const peeked = cursor.peek(metrics.header) orelse {
            failUsageRing(worker, warn_label);
            break;
        };
        const remaining = worker_shared_page.RECORD_RING_COUNT - total_seen;
        const count = peeked.copy(metrics.completed_records, 0, records[0..@min(records.len, remaining)]);
        if (count == 0)
            break;

        var appended_count: usize = 0;
        var skipped_count: usize = 0;
        var rejected_count: usize = 0;
        var advance_count: usize = 0;
        var blocked_by_reserved_synthesis = false;
        for (records[0..count]) |record| {
            if (target_identity) |identity| {
                if (accounting.usage.recordMatchesLifecycle(record, worker_key, identity))
                    result.found = true;
            }
            // A record whose synthesis is still reserved stops consumption but
            // not the scan. The ring advances by a contiguous prefix, so
            // nothing past the block may be taken; but a caller asking whether
            // the worker authored a record gets a wrong `false` if the answer
            // sits behind the block, and that `false` writes a floor over a
            // record the worker already wrote.
            if (blocked_by_reserved_synthesis)
                continue;
            const key = accounting.usage.keyFromRecord(record, worker_key);
            if (ctx.usage.synthesisState(key)) |state_for_key| {
                switch (state_for_key) {
                    .reserved => {
                        blocked_by_reserved_synthesis = true;
                        continue;
                    },
                    .written => {
                        skipped_keys[skipped_count] = key;
                        skipped_count += 1;
                        advance_count += 1;
                        continue;
                    },
                }
            }
            // The table answers per request, so a second record for a request
            // already taken in this batch is checked against the batch.
            const dispatched = worker.requests.expected(record.request_id) orelse {
                rejected_count += 1;
                advance_count += 1;
                continue;
            };
            if (std.mem.indexOfScalar(u64, appended_request_ids[0..appended_count], dispatched.request_id) != null) {
                rejected_count += 1;
                advance_count += 1;
                continue;
            }
            appended[appended_count] = usage.fromCompleted(requestIdentity(ctx, worker, dispatched.route), .worker, record, clock);
            appended[appended_count].request_id = dispatched.request_id;
            appended_request_ids[appended_count] = dispatched.request_id;
            appended_count += 1;
            advance_count += 1;
        }
        // Appended, then marked, then advanced: the ring lets go of a record
        // only once the log holds it, or a full stream dropped it, and the
        // request table knows its request has its record either way. A
        // dropped batch stays settled, so none of its requests waits for a
        // record the ring no longer holds or gets a floor over the one it
        // had. A held batch is none of that yet: nothing of it is marked,
        // counted or advanced, and the next scan reads it again.
        switch (ctx.usage.append(appended[0..appended_count], on_full)) {
            .taken => result.written += appended_count,
            // Counted by the usage log.
            .dropped => {},
            .held => {
                result.held = true;
                break;
            },
        }
        worker.requests.markUsageRecorded(appended_request_ids[0..appended_count]);
        cursor.advance(metrics.header, peeked, advance_count);
        ctx.usage.forgetWritten(skipped_keys[0..skipped_count]);
        total_seen += advance_count;
        total_rejected += rejected_count;
        stopped_on_reserved_synthesis = blocked_by_reserved_synthesis;
        if (blocked_by_reserved_synthesis or advance_count == 0)
            break;
    }
    // The consume loop stopped at the blocked record, so everything past it is
    // unexamined. Walk the rest of the ring for the identity alone: reporting
    // that the worker never authored a record while it sits a few slots further
    // in makes the server write a floor that then suppresses the worker's own
    // record, the one carrying measured CPU.
    //
    // The sweep starts at the cursor's current tail, not past what this call
    // consumed: `RecordCursor.advance` already moved the tail, so any offset
    // here would be counted twice and skip live records. Re-examining records
    // this call already checked is free, since the sweep consumes nothing and
    // only ever turns `found` true.
    if (stopped_on_reserved_synthesis)
        _ = ctx.counters.drains_blocked.fetchAdd(1, .monotonic);
    if (target_identity) |identity| {
        if (stopped_on_reserved_synthesis and !result.found) {
            result.deep_scanned = true;
            result.found = ringHoldsLifecycle(worker, metrics, identity, records[0..], warn_label);
        }
    }
    if (total_seen >= worker_shared_page.RECORD_RING_COUNT)
        std.log.warn("usage {s} capped at ring capacity for worker_id={d}", .{ warn_label, worker_key.worker_id });
    result.advanced = total_seen;
    return result;
}

/// Read-only sweep of everything still in the ring, from one peek, consuming
/// nothing. A peek that finds the ring corrupt fails it and answers false.
fn ringHoldsLifecycle(
    worker: *WorkerRecord,
    metrics: *worker_shared_page.WorkerWriterView,
    identity: worker_shared_page.LifecycleIdentity,
    scratch: []CompletedRecord,
    comptime warn_label: []const u8,
) bool {
    std.debug.assert(scratch.len != 0);
    const peeked = metrics.host_cursors.records.peek(metrics.header) orelse {
        failUsageRing(worker, warn_label);
        return false;
    };
    const worker_key = worker.key();
    var offset: u64 = 0;
    while (offset < peeked.count) {
        const count = peeked.copy(metrics.completed_records, offset, scratch);
        for (scratch[0..count]) |record| {
            if (accounting.usage.recordMatchesLifecycle(record, worker_key, identity))
                return true;
        }
        offset += count;
    }
    return false;
}

/// Stops every later drain of `worker`'s usage ring, whose head the worker
/// moved where no append puts it, and leaves the worker's fault to the
/// metrics thread (`server/ingress/analytics_drain.zig`), which can tell the
/// lanes. `worker.metrics_mutex` must be held.
fn failUsageRing(worker: *WorkerRecord, comptime warn_label: []const u8) void {
    if (worker.usage_ring_failed)
        return;
    worker.usage_ring_failed = true;
    std.log.warn("usage {s} found the usage record ring corrupt; the worker leaves service worker_id={d}", .{
        warn_label,
        worker.id,
    });
}

/// The identity a usage record of a request on `worker` carries: the worker
/// as the server's record names it, and the pattern of `route`, the route of
/// the worker's definition the request matched as its request table entry
/// recorded it (`Dispatched.route`).
fn requestIdentity(ctx: UsageDrain, worker: *const WorkerRecord, route: config.RouteIndex) analytics.Identity {
    const key: config.RouteKey = .{ .definition = worker.definition_index, .route = route };
    return .{
        .worker = worker.name,
        .route = ctx.routes.route(key).pattern,
        .worker_id = worker.id,
        .worker_generation = worker.generation,
    };
}

/// Classifies a worker death for its requests' floor records. The page starts
/// out stamped `.crash`; the sentinel stamps `.memory` before it exits under
/// memory.high pressure, while a kernel OOM kill at memory.max is a SIGKILL
/// the worker cannot stamp, so the cgroup, which survives until the
/// teardown's `Record.vacate`, is asked whether the kernel counted an
/// oom_kill. Any read error keeps `.crash`. Reads a cgroup file, so a lane
/// that runs a death calls it once for the worker, not once per request.
pub fn classifyWorkerDeath(ctx: UsageDrain, worker: *WorkerRecord) worker_shared_page.CompletedStatus {
    if (worker.handle.metrics) |*metrics| {
        // A reason outside `TerminationReason` says nothing, and the cgroup
        // decides as it does for a crash.
        const snapshot = worker_shared_page.LifecycleSnapshot.load(metrics.header);
        if (snapshot.knownTerminationReason()) |reason| {
            if (reason == .memory)
                return .memory;
        }
    }
    const events = cgroup.memory.readEventsLocal(ctx.allocator, worker.handle.cgroup_dir) catch |err| {
        std.log.warn("worker death: memory.events.local read failed for worker_id={d}: {s}", .{
            worker.id,
            @errorName(err),
        });
        return .crash;
    };
    if (events.oom_kill > 0) {
        std.log.warn("worker death classified as out-of-memory: worker_id={d} oom_kill={d}", .{
            worker.id,
            events.oom_kill,
        });
        return .memory;
    }
    return .crash;
}

/// Logs a dying worker's cgroup CPU usage without putting it on any record.
/// Kernel cgroup accounting survives SIGKILL and covers a single turn that
/// never ends, which the per-turn live-slot flush cannot see, but it spans
/// the worker's whole life, so it also holds the CPU the worker's earlier
/// records already carry; recording it would charge that CPU twice. Reads a
/// cgroup file, so it belongs on the reaper, once per worker that died,
/// before its teardown removes the cgroup.
pub fn noteWorkerDeathBurn(
    ctx: UsageDrain,
    worker: *WorkerRecord,
    status: worker_shared_page.CompletedStatus,
) void {
    const usage_usec = cgroup.cpu.readStatUsageUsec(ctx.allocator, worker.handle.cgroup_dir) catch |err| {
        std.log.debug("worker death: cpu.stat read failed for worker_id={d}: {s}", .{
            worker.id,
            @errorName(err),
        });
        return;
    };
    std.log.warn("worker death burn: worker_id={d} status={s} cgroup_cpu_usage_usec={d}", .{
        worker.id,
        @tagName(status),
        usage_usec,
    });
}

/// What a synthesis leaves the request's entry in the worker's request table
/// to wait for, which `settleRequest` passes on to the table.
pub const SynthesisOutcome = enum {
    /// Nothing: the server wrote the floor, a drain settled the worker's
    /// record, another caller owns the attempt, or the table holds no entry
    /// for the request.
    settled,
    /// No record of the request is settled, and the worker's own may still
    /// come: it sits in the ring behind another attempt's reservation, or the
    /// floor was dropped and a worker that is still alive may yet append one.
    /// The entry must keep expecting it, or the drain that finds it refuses
    /// the request's only record.
    awaits_worker_record,

    pub fn expectsWorkerRecord(self: SynthesisOutcome) bool {
        return self == .awaits_worker_record;
    }
};

/// Writes the floor usage record of `request_id`, a request the server
/// ended without a completion from `worker`, as `floor` says, unless the
/// worker already authored a record for it (`claimSynthesisForLifecycle`).
/// The floor's identity, route and flags come from the request's entry in
/// `worker.requests`, and so does its start when no live slot matches the
/// request (`synthesizeRecordForLifecycle`). A full usage stream never fails
/// the caller: a floor that finds no room is dropped and counted
/// (`UsageLog.appendFloor`), and a worker record the request may still get
/// is then left expected (`SynthesisOutcome.awaits_worker_record`). Fails
/// with `error.OutOfMemory`, writing nothing, when the exactly-once index
/// cannot grow.
pub fn synthesizeFinalAccountingForLifecycle(
    ctx: UsageDrain,
    worker: *WorkerRecord,
    request_id: u64,
    floor: Floor,
) error{OutOfMemory}!SynthesisOutcome {
    const dispatched = worker.requests.dispatchedFor(request_id) orelse return .settled;
    const identity = lifecycleIdentity(worker, dispatched);
    const claim = try claimSynthesisForLifecycle(ctx, worker, identity);
    if (!claim.reservation.active)
        return .settled;
    if (claim.worker_authored) {
        // Dropping the claim releases a worker record still in the ring: while
        // the attempt is reserved no drain may consume it, including the scan
        // that just found it. It is drained here rather than left for the
        // periodic drain because a floor is written for a request whose
        // worker is usually dying, and its page goes with the teardown.
        ctx.usage.rollbackSynthesis(claim.reservation);
        // Settled by this drain, written or dropped, unless another attempt's
        // reservation still blocks it; the table below answers which.
        _ = drainWorker(ctx, worker);
        if (worker.requests.usageRecorded(request_id))
            return .settled;
        // A later drain settles it: the periodic one, or for a dying worker
        // its teardown's (`drainFinal`).
        return .awaits_worker_record;
    }

    const clock = analytics.Clock.capture();
    const record = synthesizeRecordForLifecycle(worker, dispatched, identity, floor.status, clock.mono_now_ns);
    var floor_record = usage.fromCompleted(requestIdentity(ctx, worker, dispatched.route), .server, record, clock);
    floor_record.worker_fault = floor.worker_fault;
    switch (ctx.usage.appendFloor(&floor_record)) {
        .taken => {},
        .dropped => {
            // Rolled back rather than committed: no floor exists, so a worker
            // record for this attempt that still shows up is the one to keep.
            // The entry leaves `synthesizing` before the reservation goes: a
            // drain between the two then stops at the reserved record instead
            // of refusing it for a request whose floor is being written.
            worker.requests.finishSynthesis(request_id, false);
            ctx.usage.rollbackSynthesis(claim.reservation);
            return .awaits_worker_record;
        },
    }
    ctx.usage.commitSynthesis(claim.reservation);
    worker.requests.finishSynthesis(request_id, true);
    // Counted only on the deep-scan path: there the answer that the worker
    // never authored a record came from a walk of the whole ring rather than
    // from the consume pass, and a wrong answer records the request twice.
    if (claim.deep_scanned)
        _ = ctx.counters.floors_after_deep_scan.fetchAdd(1, .monotonic);
    return .settled;
}

/// The identity the dispatch of `dispatched` stamped on `worker`'s live slot,
/// with the server's request id as the external id.
fn lifecycleIdentity(worker: *const WorkerRecord, dispatched: request_table.Dispatched) worker_shared_page.LifecycleIdentity {
    return .{
        .external_request_id = dispatched.request_id,
        .request_lane_id = dispatched.request_key.lane_id,
        .request_slot = dispatched.request_key.slot,
        .request_generation = dispatched.request_key.generation,
        .worker_id = worker.id,
        .worker_generation = worker.generation,
        .billing_sequence = dispatched.request_id,
    };
}

/// The request id is always the server's. A live slot for the request
/// supplies what the worker measured before it died, from the one copy the
/// identity matched; without one the record is a floor that starts when the
/// server dispatched the request.
fn synthesizeRecordForLifecycle(
    worker: *WorkerRecord,
    dispatched: request_table.Dispatched,
    identity: worker_shared_page.LifecycleIdentity,
    status: worker_shared_page.CompletedStatus,
    finished_mono_ns: u64,
) CompletedRecord {
    if (worker.handle.metrics) |*metrics| {
        if (worker_shared_page.LiveSlotSnapshot.find(metrics.live_slots, identity)) |snapshot| {
            var record = worker_metrics_state.synthesizeDeathRecord(snapshot, finished_mono_ns, status);
            record.request_id = identity.external_request_id;
            record.flags = dispatched.accounting_flags;
            // A death the server caused (`internal_error`) carries no CPU;
            // one the workload caused (crash, memory, deadline) carries the
            // CPU the live slot flushed turn by turn.
            if (status == .internal_error)
                record.cpu_time_ns = 0;
            return record;
        }
    }

    return std.mem.zeroInit(CompletedRecord, .{
        .request_id = identity.external_request_id,
        .request_generation = identity.request_generation,
        .worker_id = identity.worker_id,
        .worker_generation = identity.worker_generation,
        .started_mono_ns = dispatched.started_mono_ns,
        .finished_mono_ns = finished_mono_ns,
        .request_slot = identity.request_slot,
        .request_lane_id = identity.request_lane_id,
        .status = @intFromEnum(status),
        .flags = dispatched.accounting_flags,
    });
}
