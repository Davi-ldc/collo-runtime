//! The engine's thread bodies: the owner loop (`h2Main`), which runs every
//! HTTP/2 stream and every HTTP/1 exchange of the shard, and the connector
//! loop (`h2ConnectMain`), which dials for both protocols. Each runs once
//! per engine run and returns when the run stops, leaving nothing on its
//! thread for the next run to inherit.
//!
//! The owner rebuilds its watch list only when watch-relevant state
//! changed, and every mutation of a pending list must mark it dirty before
//! the next wait, because watch contexts point into those lists. Before the
//! loop can park, the driver's armed set is reconciled with the desired one,
//! so no armed poll outlives the pending it points at. A command handed to a
//! connector is settled through that connector's completion delivery, never
//! by the owner's exit sweep, because the connector dereferences its task
//! for the whole dial. HTTP/1 and HTTP/2 share the owner thread under the
//! fairness budgets described on `H1TurnBudget`.

const std = @import("std");
const builtin = @import("builtin");
const accounting = @import("collo_egress_accounting");
const bindings = @import("collo_bindings");
const core = @import("collo_egress_core");
const data_io = @import("collo_egress_data_io");
const http2 = @import("collo_egress_http2");
const pool_mod = @import("collo_egress_pool");
const readiness = @import("collo_egress_readiness");
const transport = @import("collo_egress_transport");
const task_model = @import("../task.zig");
const result_mod = @import("result.zig");
const h2_queue = @import("h2/queue.zig");
const h2_lifecycle = @import("h2/lifecycle.zig");

const body_credit = core.body_credit;
const decompress = core.decompress;
const completeCanceled = result_mod.completeCanceled;
const publishFailure = result_mod.publishFailure;
const publishResult = result_mod.publishResult;

/// Transparent retry budget per command, matching Bun's max_h2_retries.
const max_h2_stream_retries: u8 = 5;

/// The fairness contract between h1 and h2 work on the single owner thread,
/// as two nested budgets:
///
///  - the per-drive quantum (`transport.Http1DriveBudget`, 16 reads or
///    256 KiB) bounds how long one pending may hold the thread within a
///    drive pass, so one fast bulk body cannot freeze its neighbors from
///    head to EOF;
///  - the per-turn budget (this type) bounds the whole h1 drive pass of one
///    owner iteration, at `max_pendings` driven or `max_bytes` drained,
///    whichever runs out first, so a burst of runnable h1 pendings (up to
///    the gateway policy's `max_active_fetches_per_security_cell`, 1024 by
///    default, each worth a 256 KiB quantum) cannot pile up hundreds of MiB
///    of h1 work before the h2 side of the loop runs.
///
/// Leftover runnable work never blocks in the wait. The drive pass reports
/// it, the owner wakes itself, the wait returns at once after serving
/// whatever readiness or expiry was already coalesced (one result per
/// wait), and the next iteration continues the drain, so h2 service latency
/// under an h1 burst is bounded by one turn budget whatever the size of the
/// burst. Fairness within the burst is positional: each pass restarts at the
/// head of the pending list and every yielder rotates to the back, so an
/// exhausted budget hands the next pass to the least recently driven
/// runnables instead of re-serving the same head of the list forever.
///
/// 64 pendings times the 256 KiB drive quantum caps a pass at 16 MiB in the
/// worst shape; the 4 MiB drain cap applies first once 16 or more of them
/// are streaming in bulk. Both are memory-speed work on bytes already queued
/// in socket buffers, so a full turn stays in the hundreds of microseconds.
pub const H1TurnBudget = struct {
    pub const max_pendings: usize = 64;
    pub const max_bytes: usize = 4 * 1024 * 1024;

    pendings_left: usize = max_pendings,
    bytes_left: usize = max_bytes,

    /// Gate before driving a runnable pending: exhaustion leaves the found
    /// pending runnable for the next turn instead of half-driving it.
    pub fn admitDrive(self: *H1TurnBudget) bool {
        if (self.pendings_left == 0 or self.bytes_left == 0)
            return false;
        self.pendings_left -= 1;
        return true;
    }

    /// Charge the response bytes one drive actually drained (the per-drive
    /// budget's consumed count), saturating at zero.
    pub fn chargeDrained(self: *H1TurnBudget, bytes: usize) void {
        self.bytes_left -|= bytes;
    }
};

pub fn Methods(
    comptime Engine: type,
    comptime Command: type,
    comptime H2Pending: type,
    comptime H2Watch: type,
    comptime H2Message: type,
    comptime H2Connected: type,
    comptime H2ConnectOutcome: type,
    comptime H2ConnectGroup: type,
    comptime H2ConnectKey: type,
    comptime H1Pending: type,
    comptime H1Connected: type,
    comptime WakeEvent: type,
    comptime WakeFn: type,
) type {
    const http1_pool = @import("http1_pool.zig").Methods(Engine, Command);

    return struct {
        const H2Queue = h2_queue.Methods(
            Engine,
            Command,
            H2Message,
            H2Connected,
            WakeEvent,
            WakeFn,
        );
        const H2Lifecycle = h2_lifecycle.Methods(H2Pending);

        pub fn enqueueH2MessageLocked(self: *Engine, message: H2Message) !void {
            return H2Queue.enqueueH2MessageLocked(self, message);
        }

        pub fn enqueueH2MessageAssumeCapacityLocked(self: *Engine, message: H2Message) void {
            return H2Queue.enqueueH2MessageAssumeCapacityLocked(self, message);
        }

        pub fn enqueueH2ConnectLocked(self: *Engine, command: Command) !void {
            return H2Queue.enqueueH2ConnectLocked(self, command);
        }

        pub fn enqueueH2Connect(self: *Engine, command: Command) !void {
            return H2Queue.enqueueH2Connect(self, command);
        }

        pub fn enqueueH2Connected(self: *Engine, connected: H2Connected) !void {
            return H2Queue.enqueueH2Connected(self, connected);
        }

        pub fn waitForH2Command(self: *Engine) bool {
            return H2Queue.waitForH2Command(self);
        }

        pub fn drainH2BatchNonBlocking(self: *Engine) ?usize {
            return H2Queue.drainH2BatchNonBlocking(self);
        }

        pub fn popH2Connect(self: *Engine) ?Command {
            return H2Queue.popH2Connect(self);
        }

        pub fn initH2Drivers(self: *Engine) !void {
            return H2Queue.initH2Drivers(self);
        }

        pub fn deinitH2Drivers(self: *Engine) void {
            return H2Queue.deinitH2Drivers(self);
        }

        pub fn h2DataDriver(self: *Engine, index: usize) *data_io.Driver {
            return H2Queue.h2DataDriver(self, index);
        }

        pub fn h2ReadinessDriver(self: *Engine, index: usize) *readiness.Driver {
            return H2Queue.h2ReadinessDriver(self, index);
        }

        pub fn nextH2CreditSourceId(self: *Engine) u64 {
            return H2Queue.nextH2CreditSourceId(self);
        }

        pub fn signalH2Wake(self: *Engine) void {
            return H2Queue.signalH2Wake(self);
        }

        fn removeH2Entry(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
        ) void {
            return H2Lifecycle.removeH2Entry(pool, data_driver, entry);
        }

        fn removeH2EntryIfIdle(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
        ) void {
            return H2Lifecycle.removeH2EntryIfIdle(pool, data_driver, entry);
        }

        fn removeH2EntryIfClosingAndIdle(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
        ) bool {
            return H2Lifecycle.removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
        }

        fn removeH2EntryIfLifecycleExpired(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
            now_ns: u64,
        ) bool {
            return H2Lifecycle.removeH2EntryIfLifecycleExpired(pool, data_driver, entry, now_ns);
        }

        fn evictExpiredH2Entries(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            now_ns: u64,
        ) void {
            return H2Lifecycle.evictExpiredH2Entries(pool, data_driver, now_ns);
        }

        fn findH2PendingIndex(
            pending: []const H2Pending,
            entry: *pool_mod.Entry,
            stream_id: u32,
        ) ?usize {
            return H2Lifecycle.findH2PendingIndex(pending, entry, stream_id);
        }

        /// Restarts the stall deadline on origin progress. `socket_timeout`
        /// is an idle timeout ("the origin went silent"), so every response
        /// head, interim response and body chunk from the origin restarts the
        /// clock, still bounded by the total request deadline. A failed clock
        /// read leaves the current deadline in place rather than failing an
        /// in-flight fetch on a stray clock error.
        fn refreshH2StallDeadline(item: *H2Pending) void {
            const now = readiness.monotonicNowNs() catch return;
            item.deadline_mono_ns = item.command.config.stallDeadlineFromNow(now);
        }

        fn findH2PendingIndexByBodyCredit(
            pending: []const H2Pending,
            credit: body_credit.H2Data,
        ) ?usize {
            return H2Lifecycle.findH2PendingIndexByBodyCredit(pending, credit);
        }

        /// Folds this attempt's meters into the fetch body as absolute
        /// totals: the task's cross-hop base (finished redirect hops plus
        /// retried attempts' cost) plus the live attempt. setEgressMeters
        /// keeps the maximum per field, so re-folding after every origin
        /// event is idempotent.
        fn foldH2PendingMetersIntoBody(item: *H2Pending) void {
            const base = item.command.task.egressBase();
            item.body.setEgressMeters(.{
                .billed_sent = base.billed_sent +| item.billed_bytes.sent,
                .billed_received = base.billed_received +| item.billed_bytes.received,
                .cost = base.cost +| item.cost_bytes,
            });
        }

        fn findH2PendingIndexByH2Identity(
            pending: []const H2Pending,
            source_id: u64,
            stream_id: u32,
        ) ?usize {
            return H2Lifecycle.findH2PendingIndexByH2Identity(pending, source_id, stream_id);
        }

        fn findH2PendingIndexByBodyIdentity(
            pending: []const H2Pending,
            identity: bindings.FetchBodyIdentity,
        ) ?usize {
            return H2Lifecycle.findH2PendingIndexByBodyIdentity(pending, identity);
        }

        fn drainH2Wake(fd: std.posix.fd_t) void {
            return H2Lifecycle.drainH2Wake(fd);
        }

        fn cancelH2StreamBestEffort(
            pool: *pool_mod.Pool,
            stream: pool_mod.StreamHandle,
            context: []const u8,
        ) void {
            return H2Lifecycle.cancelH2StreamBestEffort(pool, stream, context);
        }

        fn ackH2DataBestEffort(
            pool: *pool_mod.Pool,
            entry: *pool_mod.Entry,
            stream_id: u32,
            encoded_bytes: usize,
            update_stream_window: bool,
            context: []const u8,
        ) void {
            return H2Lifecycle.ackH2DataBestEffort(
                pool,
                entry,
                stream_id,
                encoded_bytes,
                update_stream_window,
                context,
            );
        }

        fn failFetchBodyBestEffort(
            body: anytype,
            allocator: std.mem.Allocator,
            message: []const u8,
            context: []const u8,
        ) void {
            return H2Lifecycle.failFetchBodyBestEffort(body, allocator, message, context);
        }

        fn h2LimitsEqual(a: http2.Limits, b: http2.Limits) bool {
            return H2Lifecycle.h2LimitsEqual(a, b);
        }

        pub fn h2ConnectMain(self: *Engine, connector_index: usize) void {
            const readiness_driver = self.h2ReadinessDriver(connector_index);
            const data_driver = self.h2DataDriver(connector_index + 1);

            while (self.popH2Connect()) |command| {
                if (command.h1_connect)
                    completeH1Connect(self, command, readiness_driver)
                else
                    completeH2Connect(self, command, readiness_driver, data_driver);
            }
        }

        /// Owner loop. Returns an error only when the owner can no longer
        /// work: a watch-list build or driver reconcile that will keep
        /// failing, such as an allocation at the shard memory budget or a
        /// dead ring. It first settles everything the owner owns, then
        /// propagates, so the shard supervisor restarts the engine instead of
        /// the owner spinning on a failure that will repeat.
        pub fn h2Main(self: *Engine) !void {
            var pool = pool_mod.Pool.init(self.allocator, .{});
            defer pool.deinit();
            const data_driver = self.h2DataDriver(0);
            defer data_driver.cancelAllConnections();
            var pending = std.array_list.Aligned(H2Pending, null).empty;
            defer pending.deinit(self.allocator);
            var connecting = std.array_list.Aligned(H2ConnectGroup, null).empty;
            defer {
                for (connecting.items) |*group|
                    group.deinit(self.allocator);
                connecting.deinit(self.allocator);
            }
            var data_sources = std.array_list.Aligned(data_io.Source, null).empty;
            defer data_sources.deinit(self.allocator);
            var watch_contexts = std.array_list.Aligned(H2Watch, null).empty;
            defer watch_contexts.deinit(self.allocator);

            var clock_cursor_ns: u64 = readiness.monotonicNowNs() catch 0;
            // The watch list is rebuilt only when watch-relevant state
            // changed (pendings or entries added or removed, pump or pause
            // flips, I/O events). The most common iteration, a credit ack
            // below the window-update threshold, leaves it untouched and
            // skips the rebuild and the eviction scan entirely. Every
            // mutation path must set this flag before the next wait, because
            // contexts hold pointers into `pending.items`. The driver's
            // watchdog tick (`.tick`) forces a rebuild at least once per tick
            // interval (`watchdog_tick_ns` in io/bio_data.zig), bounding any
            // staleness (paused-deadline refresh, eviction delay) to one
            // tick.
            var watch_dirty = true;
            // Set when the last drive pass left runnable h1 work behind: a
            // pending yielded its per-drive quantum, or the per-turn budget
            // (H1TurnBudget) ran out mid-pass. Runnable pendings have no
            // watch source, so the owner wakes itself and forces the next
            // iteration dirty to come back to them; the wait never blocks on
            // the self-wake and still surfaces whatever else was already
            // ready.
            var h1_more_runnable = false;
            while (true) {
                const batch_len = self.drainH2BatchNonBlocking() orelse {
                    // Tear down all owner work, beyond the pending sweeps:
                    // idle keep-alive entries survive failAllH2Pending, and
                    // this exit's defers run pool.deinit after
                    // cancelAllConnections. A cancel the kernel has not
                    // confirmed quarantines its connection and hands the wire
                    // to the driver, but pool.deinit destroys entries
                    // unconditionally: it would free a wire whose buffers
                    // in-flight kernel operations still reference, and the
                    // driver's final sweep would free it again.
                    // failAllOwnerWork drains the pool through removeH2Entry,
                    // which preserves quarantined wires for the driver and
                    // destroys everything else, so both defers see an empty
                    // pool.
                    failAllOwnerWork(self, &pool, &pending, data_driver, error.EgressEngineStopped);
                    failAllH2Connecting(&connecting, error.EgressEngineStopped, self.wake_ctx, self.wake_fn.?, self.allocator);
                    failH2RetryCommands(self, error.EgressEngineStopped);
                    failH2PoolWaiters(self, error.EgressEngineStopped);
                    return;
                };
                if (batch_len != 0)
                    drainH2Wake(self.h2_wake_fd);
                self.h2_stats.countIteration(batch_len);
                // wakeCancellation requests an immediate sweep: an eventfd
                // wake alone is not watch-dirty, and flag-only cancels would
                // otherwise wait for the watchdog tick.
                if (self.cancel_sweep_requested.swap(false, .acq_rel))
                    watch_dirty = true;
                if (h1_more_runnable) {
                    h1_more_runnable = false;
                    watch_dirty = true;
                }

                for (self.h2_batch[0..batch_len]) |message| switch (message) {
                    .request => |command| {
                        startAnyCommand(self, &pool, &pending, &connecting, data_driver, command);
                        watch_dirty = true;
                    },
                    .connected => |connected| {
                        startConnectedH2Command(self, &pool, &pending, &connecting, data_driver, connected);
                        watch_dirty = true;
                    },
                    .h1_connected => |connected| {
                        applyH1Connected(self, connected);
                        watch_dirty = true;
                    },
                    .h1_resume => |source_id| {
                        if (applyH1Resume(self, source_id))
                            watch_dirty = true;
                    },
                    .body_credit => |credit| {
                        if (applyH2BodyCredit(self, &pool, &pending, data_driver, credit))
                            watch_dirty = true;
                    },
                    .body_cancel => |identity| {
                        applyH2BodyCancel(self, &pool, &pending, data_driver, identity);
                        applyH1BodyCancel(self, identity);
                        watch_dirty = true;
                    },
                };
                if (drainH2Retries(self, &pool, &pending, &connecting, data_driver))
                    watch_dirty = true;
                const maintain_start_ns = readiness.monotonicNowNs() catch clock_cursor_ns;
                self.h2_stats.addProcess(maintain_start_ns -| clock_cursor_ns);

                // The cancel scan locks every pending body's mutex, so it
                // runs only on dirty iterations: message-driven cancels
                // (`.body_cancel`) mark dirty and are caught immediately;
                // flag-only cancels are caught by the next dirty iteration
                // or the watchdog tick, at most one tick later.
                if (watch_dirty) {
                    _ = cancelH2Pending(self, &pool, &pending, data_driver, self.wake_ctx, self.wake_fn.?);
                    cancelH1Pending(self);
                    const maintain_now_ns = readiness.monotonicNowNs() catch std.math.maxInt(u64);
                    evictExpiredH2Entries(&pool, data_driver, maintain_now_ns);
                    expireH2PoolWaiters(self, maintain_now_ns);
                    _ = drainH2PoolWaiters(self, &pool, &pending, &connecting, data_driver);
                    _ = drainH2Retries(self, &pool, &pending, &connecting, data_driver);
                    // Step every runnable h1 pending until it parks,
                    // completes, or exhausts a fairness budget (the
                    // per-drive quantum or the per-turn H1TurnBudget). Every
                    // event that makes a pending runnable marks the watch
                    // dirty, so this pass never starves. Leftover runnable
                    // work wakes the owner: the wait below returns at once,
                    // after surfacing any already-ready source, and the
                    // carryover flag re-runs this pass, so other pendings
                    // and h2 watches are serviced between drain batches.
                    h1_more_runnable = driveRunnableH1(self, &pool, &pending, &connecting, data_driver);
                    if (h1_more_runnable)
                        self.signalH2Wake();
                }

                // Reconcile the driver's armed set with the desired set on
                // every dirty iteration, before the loop can go idle,
                // including the transition to zero sources (disarm all).
                // Watch contexts hold pointers into the pending lists, so a
                // persistent poll surviving its pending would deliver a late
                // completion into freed or moved memory; after this
                // reconcile no armed poll can outlive the pending it points
                // at, on any path to any park (the kernel wait or the idle
                // condvar below).
                if (watch_dirty) {
                    const build_result: anyerror!void = if (takeInjectedOwnerFault(self, "test_h2_build_fault")) |err|
                        err
                    else
                        buildH2DataWatchList(&data_sources, &watch_contexts, &pool, pending.items, self.h1_pending.items, self.allocator);
                    build_result catch |err| {
                        // The desired watch set can no longer be computed. At
                        // the shard memory budget this allocation failure is
                        // sticky: every retry fails again, and carrying on
                        // would spin with h1 pendings stranded forever.
                        // Settle everything the owner owns (both protocols,
                        // coalesced connects, retry scratch, pool waiters),
                        // disarm the fd watches, and let the error escape
                        // h2Main so the shard supervisor restarts the engine.
                        failAllOwnerWork(self, &pool, &pending, data_driver, err);
                        failAllH2Connecting(&connecting, err, self.wake_ctx, self.wake_fn.?, self.allocator);
                        failH2RetryCommands(self, err);
                        failH2PoolWaiters(self, err);
                        return err;
                    };
                    self.h2_stats.recordWatchLen(data_sources.items.len);
                    const sync_result: anyerror!void = if (takeInjectedOwnerFault(self, "test_h2_sync_fault")) |err|
                        err
                    else
                        data_driver.syncSources(data_sources.items);
                    sync_result catch |err| {
                        // A failed reconcile means the driver cannot be
                        // trusted to watch anything, and ring-level failures
                        // (dead ring, exhausted submission-queue policy) are
                        // sticky. Carrying on would re-enter this sync on the
                        // next dirty iteration, and failAllOwnerWork's own
                        // empty re-sync swallows its failure by design, so the
                        // owner would spin forever without latching the owner
                        // fault. Escape as for a failed build: settle
                        // everything the owner owns and let the error out of
                        // h2Main to the shard supervisor. Per-source
                        // watch-cap rejections never reach this handler: the
                        // driver confines them to the offending source and
                        // serves them as `.failed` wait results. The empty
                        // re-sync inside failAllOwnerWork retires tokens in
                        // userspace first, so the disarm stays safe even when
                        // the ring flush itself is what failed.
                        failAllOwnerWork(self, &pool, &pending, data_driver, err);
                        failAllH2Connecting(&connecting, err, self.wake_ctx, self.wake_fn.?, self.allocator);
                        failH2RetryCommands(self, err);
                        failH2PoolWaiters(self, err);
                        return err;
                    };
                    watch_dirty = false;
                }
                // Idle guard: `.awaiting_connect` pendings do not keep the
                // loop out of the condvar park. They contribute no watch
                // source or deadline, and their wake is the connector's
                // completion enqueue (h2_condition plus the eventfd), which
                // the park below observes. Counting them would spin the loop
                // through the data wait for the whole dial, and after a
                // failed data wait the driver cannot wait at all while the
                // failure sweep leaves exactly these pendings behind.
                if (pending.items.len == 0 and !hasOwnerDrivenH1Work(self) and !pool.hasOutgoing() and !pool.hasEntries()) {
                    if (batch_len == 0) {
                        const wait_start_ns = readiness.monotonicNowNs() catch clock_cursor_ns;
                        self.h2_stats.addBusy(wait_start_ns -| clock_cursor_ns);
                        const keep_running = self.waitForH2Command();
                        clock_cursor_ns = readiness.monotonicNowNs() catch wait_start_ns;
                        self.h2_stats.addWait(clock_cursor_ns -| wait_start_ns);
                        if (!keep_running) {
                            // The park guard checks only pendings, the pool
                            // and owner-driven h1 work, so commands coalesced
                            // in connect groups, and connector-held
                            // `.awaiting_connect` h1 pendings that the sweep
                            // below skips, can still be in flight here.
                            // drainQueuesOnStop relies on the owner settling
                            // what it owns, as on the exit above; skipping
                            // this would hang those fetches forever.
                            failAllH1Pending(self, error.EgressEngineStopped);
                            failAllH2Connecting(&connecting, error.EgressEngineStopped, self.wake_ctx, self.wake_fn.?, self.allocator);
                            failH2RetryCommands(self, error.EgressEngineStopped);
                            failH2PoolWaiters(self, error.EgressEngineStopped);
                            return;
                        }
                    }
                    continue;
                }

                const wait_start_ns = readiness.monotonicNowNs() catch clock_cursor_ns;
                self.h2_stats.addMaintain(wait_start_ns -| maintain_start_ns);
                self.h2_stats.addBusy(wait_start_ns -| clock_cursor_ns);
                const wait_result: anyerror!data_io.Result = if (takeInjectedOwnerFault(self, "test_h2_wait_fault")) |err|
                    err
                else
                    data_driver.wait(data_sources.items, self.h2_wake_fd);
                const wait_value = wait_result catch |err| {
                    clock_cursor_ns = readiness.monotonicNowNs() catch wait_start_ns;
                    self.h2_stats.addWait(clock_cursor_ns -| wait_start_ns);
                    // A failed wait means the driver can no longer deliver
                    // readiness or deadlines: retrying would spin and parking
                    // on it would strand every pending forever. Fail both
                    // pending lists, since h1 pendings left behind would hold
                    // the idle guard open and spin, drop the pooled entries
                    // nothing can watch anymore, and disarm; the loop then
                    // parks in waitForH2Command until new work arrives.
                    failAllOwnerWork(self, &pool, &pending, data_driver, err);
                    watch_dirty = true;
                    continue;
                };
                clock_cursor_ns = readiness.monotonicNowNs() catch wait_start_ns;
                self.h2_stats.addWait(clock_cursor_ns -| wait_start_ns);
                const handle_start_ns = clock_cursor_ns;
                if (handleH2DataWaitResult(
                    self,
                    &pool,
                    &pending,
                    &connecting,
                    data_driver,
                    wait_value,
                ))
                    watch_dirty = true;
                if (drainH2Retries(self, &pool, &pending, &connecting, data_driver))
                    watch_dirty = true;
                clock_cursor_ns = readiness.monotonicNowNs() catch handle_start_ns;
                self.h2_stats.addHandle(clock_cursor_ns -| handle_start_ns);
                self.h2_stats.addBusy(clock_cursor_ns -| handle_start_ns);
            }
        }

        fn startH2Command(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            command: Command,
        ) void {
            const wake_ctx = engine.wake_ctx;
            const wake_fn = engine.wake_fn.?;
            if (command.task.isCanceled()) {
                completeCanceled(command.task, wake_ctx, wake_fn);
                return;
            }

            const request: pool_mod.BatchRequest = .{
                .allocator = pool.allocator,
                .url = command.task.url,
                .method = command.task.method,
                .body = command.task.body,
                .headers = command.task.headers,
                .config = command.config,
            };

            switch (pool.startRequestWithDriver(request, data_driver) catch |err| {
                publishFailure(command.task, err, wake_ctx, wake_fn);
                return;
            }) {
                .pending => |stream| {
                    // Same stall-deadline policy as the on-progress refresh
                    // (stallDeadlineFromNow), so open and refresh never
                    // diverge.
                    const deadline_mono_ns = command.config.stallDeadlineFromNow(readiness.monotonicNowNs() catch |err| {
                        cancelH2StreamBestEffort(pool, stream, "deadline setup");
                        removeH2EntryIfIdle(pool, data_driver, stream.entry);
                        publishFailure(command.task, err, wake_ctx, wake_fn);
                        return;
                    });
                    var pending_item = H2Pending.init(command, stream, deadline_mono_ns, engine.nextH2CreditSourceId());
                    pending.append(pool.allocator, pending_item) catch |err| {
                        pending_item.deinit(pool.allocator);
                        cancelH2StreamBestEffort(pool, stream, "pending append");
                        removeH2EntryIfIdle(pool, data_driver, stream.entry);
                        publishFailure(command.task, err, wake_ctx, wake_fn);
                    };
                },
                .needs_connection => enqueueH2ConnectOrWait(engine, connecting, command) catch |err|
                    publishFailure(command.task, err, wake_ctx, wake_fn),
                .failed => |err| publishH2StartFailure(engine, command, err),
                .entry_failed => |failed| {
                    failH2PendingForEntry(engine, pool, pending, failed.entry, failed.err, wake_ctx, wake_fn);
                    removeH2Entry(pool, data_driver, failed.entry);
                    // The open may have flushed partial frames before
                    // failing, so only idempotent bodyless requests replay.
                    if (failed.reused and
                        h2RetryEligibleCommand(command) and
                        isH2IdempotentReplayable(command))
                    {
                        queueH2RetryCommand(engine, command);
                    } else {
                        publishFailure(command.task, failed.err, wake_ctx, wake_fn);
                    }
                },
            }
        }

        fn startConnectedH2Command(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            connected: H2Connected,
        ) void {
            var message = connected;
            const wake_ctx = engine.wake_ctx;
            const wake_fn = engine.wake_fn.?;
            const group_index = findH2ConnectGroupIndex(connecting.items, message.command) orelse {
                switch (message.outcome) {
                    .h2, .h1 => |*wire| wire.deinit(),
                    .failure => {},
                }
                return;
            };
            var group = connecting.orderedRemove(group_index);
            defer group.deinit(engine.allocator);

            cancelH2ConnectingGroup(&group, wake_ctx, wake_fn);

            switch (message.outcome) {
                .failure => |err| {
                    failH2ConnectGroup(engine, &group, err);
                    return;
                },
                .h2 => |wire| adoptH2ConnectedWire(engine, pool, pending, connecting, data_driver, &group, wire) catch |err| {
                    failH2ConnectGroup(engine, &group, err);
                    return;
                },
                .h1 => |wire| adoptH1ConnectedWire(engine, &group, wire),
            }
        }

        fn startH2Outcome(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            command: Command,
            outcome: pool_mod.StartResult,
        ) void {
            const wake_ctx = engine.wake_ctx;
            const wake_fn = engine.wake_fn.?;
            switch (outcome) {
                .pending => |stream| {
                    // Same stall-deadline policy as the on-progress refresh.
                    const deadline_mono_ns = command.config.stallDeadlineFromNow(readiness.monotonicNowNs() catch |err| {
                        cancelH2StreamBestEffort(pool, stream, "adopted deadline setup");
                        removeH2EntryIfIdle(pool, data_driver, stream.entry);
                        publishFailure(command.task, err, wake_ctx, wake_fn);
                        return;
                    });
                    var pending_item = H2Pending.init(command, stream, deadline_mono_ns, engine.nextH2CreditSourceId());
                    pending.append(pool.allocator, pending_item) catch |err| {
                        pending_item.deinit(pool.allocator);
                        cancelH2StreamBestEffort(pool, stream, "adopted pending append");
                        removeH2EntryIfIdle(pool, data_driver, stream.entry);
                        publishFailure(command.task, err, wake_ctx, wake_fn);
                    };
                },
                .needs_connection => publishFailure(command.task, error.Http2ConnectionNotAdopted, wake_ctx, wake_fn),
                .failed => |err| publishH2StartFailure(engine, command, err),
                .entry_failed => |failed| {
                    failH2PendingForEntry(engine, pool, pending, failed.entry, failed.err, wake_ctx, wake_fn);
                    removeH2Entry(pool, data_driver, failed.entry);
                    // The open may have flushed partial frames before
                    // failing, so only idempotent bodyless requests replay.
                    if (failed.reused and
                        h2RetryEligibleCommand(command) and
                        isH2IdempotentReplayable(command))
                    {
                        queueH2RetryCommand(engine, command);
                    } else {
                        publishFailure(command.task, failed.err, wake_ctx, wake_fn);
                    }
                },
            }
        }

        fn adoptH2ConnectedWire(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            group: *H2ConnectGroup,
            wire: transport.HttpConnection,
        ) !void {
            if (group.commands.items.len == 0) {
                var unused_wire = wire;
                // The handshake finished after every command in the group was
                // canceled, so this connection never joins the pool.
                unused_wire.deinit();
                return;
            }

            const first = group.commands.orderedRemove(0).command;
            const first_outcome = pool.adoptConnectionWithDriver(.{
                .allocator = pool.allocator,
                .url = first.task.url,
                .method = first.task.method,
                .body = first.task.body,
                .headers = first.task.headers,
                .config = first.config,
            }, wire, data_driver) catch |err| {
                // `first` already left the group, so the caller's
                // failH2ConnectGroup only reaches the remaining members;
                // complete it here or its fetch never settles. The pool
                // deinits the wire on its own error paths.
                if (first.task.isCanceled())
                    completeCanceled(first.task, engine.wake_ctx, engine.wake_fn.?)
                else
                    publishFailure(first.task, err, engine.wake_ctx, engine.wake_fn.?);
                return err;
            };
            startH2Outcome(engine, pool, pending, data_driver, first, first_outcome);

            while (group.commands.items.len != 0) {
                const command = group.commands.orderedRemove(0).command;
                startH2Command(engine, pool, pending, connecting, data_driver, command);
            }
        }

        /// ALPN chose http/1.1: remember the origin so future submits skip
        /// the h2 path, park the handshaken connection in the shared HTTP/1
        /// pool, and restart every coalesced command on the owner-loop HTTP/1
        /// path, where the first exchange to look up a connection leases the
        /// parked one instead of dialing again.
        fn adoptH1ConnectedWire(engine: *Engine, group: *H2ConnectGroup, wire: transport.HttpConnection) void {
            var owned_wire = wire;
            if (group.commands.items.len == 0) {
                // Every command in the group was canceled during the
                // handshake, so the connection is dropped, as in
                // adoptH2ConnectedWire.
                owned_wire.deinit();
                return;
            }
            const first = group.commands.items[0].command;
            http1_pool.rememberOrigin(engine, first);
            if (engine.http1_shared_pool) |*shared_pool| {
                if (transport.prepareRequest(
                    engine.allocator,
                    first.task.url,
                    first.task.method,
                    first.task.headers,
                    first.config,
                )) |prepared| {
                    var plan = prepared;
                    defer plan.deinit();
                    shared_pool.putAdopted(&plan, first.config, owned_wire);
                } else |_| {
                    owned_wire.deinit();
                }
            } else {
                owned_wire.deinit();
            }
            while (group.commands.items.len != 0) {
                const command = group.commands.orderedRemove(0).command;
                startH1Command(engine, command);
            }
        }

        fn enqueueH2ConnectOrWait(
            engine: *Engine,
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            command: Command,
        ) !void {
            var key = try H2ConnectKey.init(engine.allocator, command);
            var key_owned = true;
            errdefer if (key_owned)
                key.deinit(engine.allocator);

            const joined_mono_ns = readiness.monotonicNowNs() catch 0;
            if (findH2ConnectGroupIndexByKey(connecting.items, key)) |index| {
                try connecting.items[index].commands.append(engine.allocator, .{
                    .command = command,
                    .joined_mono_ns = joined_mono_ns,
                });
                return;
            }

            var group = H2ConnectGroup{ .key = key, .dispatched = command };
            key_owned = false;
            var group_owned = true;
            errdefer if (group_owned)
                group.deinit(engine.allocator);
            try group.commands.append(engine.allocator, .{
                .command = command,
                .joined_mono_ns = joined_mono_ns,
            });
            try connecting.append(engine.allocator, group);
            group_owned = false;
            const group_index = connecting.items.len - 1;
            engine.enqueueH2Connect(command) catch |err| {
                var removed = connecting.orderedRemove(group_index);
                removed.deinit(engine.allocator);
                return err;
            };
        }

        fn findH2ConnectGroupIndex(groups: []const H2ConnectGroup, command: Command) ?usize {
            for (groups, 0..) |group, index|
                if (group.key.matchesCommand(command))
                    return index;
            return null;
        }

        fn findH2ConnectGroupIndexByKey(groups: []const H2ConnectGroup, key: H2ConnectKey) ?usize {
            for (groups, 0..) |group, index| {
                if (group.key.port == key.port and
                    group.key.insecure_tls == key.insecure_tls and
                    group.key.allow_private_networks == key.allow_private_networks and
                    h2LimitsEqual(group.key.h2_limits, key.h2_limits) and
                    group.key.max_outgoing_buffer_bytes == key.max_outgoing_buffer_bytes and
                    group.key.tls_ciphertext_buffer_bytes == key.tls_ciphertext_buffer_bytes and
                    std.mem.eql(u8, &group.key.pool_security_cell_id, &key.pool_security_cell_id) and
                    std.mem.eql(u8, &group.key.pool_policy_id, &key.pool_policy_id) and
                    std.mem.eql(u8, group.key.authority_host_lower, key.authority_host_lower))
                    return index;
            }
            return null;
        }

        fn cancelH2ConnectingGroup(group: *H2ConnectGroup, wake_ctx: ?*anyopaque, wake_fn: WakeFn) void {
            var index: usize = 0;
            while (index < group.commands.items.len) {
                const command = group.commands.items[index].command;
                if (!command.task.isCanceled()) {
                    index += 1;
                    continue;
                }
                _ = group.commands.orderedRemove(index);
                completeCanceled(command.task, wake_ctx, wake_fn);
            }
        }

        fn isH2ConnectTimeoutError(err: anyerror) bool {
            return err == error.FetchConnectTimeout or
                err == error.TlsHandshakeTimeout;
        }

        fn failH2ConnectGroup(engine: *Engine, group: *H2ConnectGroup, err: anyerror) void {
            const now_ns = readiness.monotonicNowNs() catch std.math.maxInt(u64);
            while (group.commands.items.len != 0) {
                const waiter = group.commands.orderedRemove(0);
                const command = waiter.command;
                // A member's connect budget runs from its own join, not the
                // leader's dispatch: late joiners whose budget and request
                // deadline still have room get a fresh attempt instead of
                // inheriting the leader's timeout, since nothing reached the
                // wire for them. The leader's own budget has expired by
                // construction, so it fails here.
                const member_deadline_ns = addNsSaturating(
                    waiter.joined_mono_ns,
                    @as(u64, command.config.socket_timeout_ms) * std.time.ns_per_ms,
                );
                if (command.task.isCanceled()) {
                    completeCanceled(command.task, engine.wake_ctx, engine.wake_fn.?);
                } else if (isH2ConnectTimeoutError(err) and
                    now_ns < member_deadline_ns and
                    !command.config.requestDeadlineExpiredAt(now_ns) and
                    h2RetryEligibleCommand(command))
                {
                    queueH2RetryCommand(engine, command);
                } else {
                    publishH2StartFailure(engine, command, err);
                }
            }
        }

        fn addNsSaturating(base: u64, delta: u64) u64 {
            return std.math.add(u64, base, delta) catch std.math.maxInt(u64);
        }

        /// Owner-exit settlement for coalesced connect groups. Every live
        /// group has exactly one dispatched command in flight at a connector
        /// (from enqueueH2ConnectOrWait until startConnectedH2Command removes
        /// the group), and the connector dereferences that command's task
        /// throughout its dial, so publishing its failure here could release
        /// the task's last reference while the connector still uses it. Only
        /// members never handed to a connector settle here. The dispatched
        /// command settles through the connector's own completion delivery:
        /// the owner's startConnectedH2Command while it still runs,
        /// publishH2Connected's stopped path when stop refuses the handoff,
        /// or drainQueuesOnStop for outcomes and never-popped commands nobody
        /// consumed.
        fn failAllH2Connecting(
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            err: anyerror,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
            allocator: std.mem.Allocator,
        ) void {
            while (connecting.items.len != 0) {
                var group = connecting.orderedRemove(0);
                defer group.deinit(allocator);
                var dispatched_skipped = false;
                while (group.commands.items.len != 0) {
                    const command = group.commands.orderedRemove(0).command;
                    if (!dispatched_skipped and command.task == group.dispatched.task) {
                        // In flight at a connector; its completion delivery
                        // settles this task after the last dereference.
                        dispatched_skipped = true;
                        continue;
                    }
                    if (command.task.isCanceled())
                        completeCanceled(command.task, wake_ctx, wake_fn)
                    else
                        publishFailure(command.task, err, wake_ctx, wake_fn);
                }
            }
        }

        fn completeH2Connect(
            engine: *Engine,
            command: Command,
            readiness_driver: *readiness.Driver,
            data_driver: *data_io.Driver,
        ) void {
            if (command.task.isCanceled()) {
                // Never complete locally: the owner must see an outcome for
                // every dispatched connect, or the ConnectGroup stays in
                // `connecting` forever, its coalesced followers hang, and
                // every later command for this origin joins the orphaned
                // group without dispatching a connector. The owner completes
                // the canceled leader in cancelH2ConnectingGroup when it
                // handles this outcome.
                publishH2Connected(engine, .{
                    .command = command,
                    .outcome = .{ .failure = error.FetchAborted },
                });
                return;
            }

            var plan = transport.prepareRequest(
                engine.allocator,
                command.task.url,
                command.task.method,
                command.task.headers,
                command.config,
            ) catch |err| {
                publishH2Connected(engine, .{ .command = command, .outcome = .{ .failure = err } });
                return;
            };
            defer plan.deinit();
            if (plan.target.protocol != .tls) {
                publishH2Connected(engine, .{ .command = command, .outcome = .{ .failure = error.Http2UnsupportedScheme } });
                return;
            }
            http2.validateRequestHead(plan.h2RequestHead(command.task.body)) catch |err| {
                publishH2Connected(engine, .{ .command = command, .outcome = .{ .failure = err } });
                return;
            };

            const outcome: H2ConnectOutcome = if (pool_mod.Entry.connectBio(
                engine.allocator,
                &plan,
                command.config,
                &engine.dns_cache,
                readiness_driver,
                data_driver,
            )) |connected| switch (connected) {
                .h2 => |wire| .{ .h2 = wire },
                .h1 => |wire| .{ .h1 = wire },
            } else |err| .{ .failure = err };
            publishH2Connected(engine, .{ .command = command, .outcome = outcome });
        }

        fn publishH2Connected(engine: *Engine, connected: H2Connected) void {
            var message = connected;
            engine.enqueueH2Connected(message) catch |err| {
                switch (message.outcome) {
                    .h2, .h1 => |*wire| wire.deinit(),
                    .failure => {},
                }
                if (err != error.EgressEngineStopped)
                    std.debug.panic("HTTP/2 connector completion handoff failed: {s}", .{@errorName(err)});
                // Stop refused the handoff. The owner's exit settlement skips
                // this dispatched command because this connector was still
                // executing it, and settles only its coalesced followers.
                // With no `.connected` message for drainQueuesOnStop to
                // consume, this return path is the completion delivery, so
                // settle the task here, after the connector's last
                // dereference.
                if (message.command.task.isCanceled())
                    completeCanceled(message.command.task, engine.wake_ctx, engine.wake_fn.?)
                else
                    publishFailure(message.command.task, error.EgressEngineStopped, engine.wake_ctx, engine.wake_fn.?);
            };
        }

        fn buildH2DataWatchList(
            sources: *std.array_list.Aligned(data_io.Source, null),
            contexts: *std.array_list.Aligned(H2Watch, null),
            pool: *pool_mod.Pool,
            pending: []H2Pending,
            h1_pending: []H1Pending,
            allocator: std.mem.Allocator,
        ) !void {
            sources.clearRetainingCapacity();
            contexts.clearRetainingCapacity();
            try sources.ensureTotalCapacity(allocator, pool.entries.items.len + h1_pending.len);
            try contexts.ensureTotalCapacity(allocator, pool.entries.items.len + h1_pending.len);
            for (pool.entries.items, 0..) |entry, index| {
                entry.watch_scratch = index;
                contexts.appendAssumeCapacity(.{
                    .pending = null,
                    .entry = entry,
                });
            }
            // Single pass over pendings: pick each entry's earliest-deadline
            // pending in O(entries + pendings), evaluating each pending's
            // effective deadline exactly once.
            for (pending) |*item| {
                const scratch = item.stream.entry.watch_scratch;
                if (scratch >= contexts.items.len or contexts.items[scratch].entry != item.stream.entry)
                    continue;
                const context = &contexts.items[scratch];
                const deadline = item.effectiveDeadlineMonoNs();
                if (context.pending == null or deadline < context.deadline_mono_ns) {
                    context.pending = item;
                    context.deadline_mono_ns = deadline;
                }
            }
            for (contexts.items) |*context| {
                const entry = context.entry.?;
                const bio = entry.bioTls() orelse return error.MixedHttp2TransportDataPath;
                const idle = context.pending == null and entry.isIdle();
                sources.appendAssumeCapacity(.{
                    .context = @ptrCast(context),
                    .connection = bio,
                    .deadline_mono_ns = if (context.pending != null) context.deadline_mono_ns else if (idle) pool.entryLifecycleDeadlineNs(entry) else std.math.maxInt(u64),
                    .want_read = (context.pending != null or idle or entry.wantsOutgoingRead()) and !entry.remote_eof,
                    .want_write = entry.wantsOutgoingWrite(),
                });
            }
            // HTTP/1 watches share the same wait: io parks poll their fd with
            // the pending's stall deadline; credit parks contribute a
            // deadline-only source (total request deadline) so a stalled
            // consumer cannot outlive the fetch's own budget. Capacity was
            // reserved upfront, so context pointers stay stable.
            for (h1_pending) |*item| {
                switch (item.park) {
                    .io => |io| {
                        contexts.appendAssumeCapacity(.{
                            .pending = null,
                            .entry = null,
                            .h1 = item,
                            .deadline_mono_ns = io.deadline_mono_ns,
                        });
                        const context = &contexts.items[contexts.items.len - 1];
                        sources.appendAssumeCapacity(.{
                            .context = @ptrCast(context),
                            // Stable identity for the driver's persistent
                            // poll diff: fd numbers are reused and contexts
                            // move with this list.
                            .source_id = item.source_id,
                            .fd = io.fd,
                            .deadline_mono_ns = io.deadline_mono_ns,
                            .want_read = io.interest == .read,
                            .want_write = io.interest == .write,
                        });
                    },
                    // Deadline-only parks: a credit park waits on the
                    // consumer (total request deadline), a dial-retry park
                    // waits on its retry tick (capped by the same total
                    // deadline). Neither has an fd to poll.
                    .credit, .dial_retry => {
                        const deadline = item.effectiveDeadlineMonoNs();
                        if (deadline == std.math.maxInt(u64))
                            continue;
                        contexts.appendAssumeCapacity(.{
                            .pending = null,
                            .entry = null,
                            .h1 = item,
                            .deadline_mono_ns = deadline,
                        });
                        const context = &contexts.items[contexts.items.len - 1];
                        sources.appendAssumeCapacity(.{
                            .context = @ptrCast(context),
                            .deadline_mono_ns = deadline,
                            .want_read = false,
                            .want_write = false,
                        });
                    },
                    .awaiting_connect, .runnable => {},
                }
            }
        }

        /// Returns true when the result mutated watch-relevant state, so the
        /// owner must rebuild its watch list before the next wait. An eventfd
        /// wake mutates nothing itself, since the messages it announces
        /// decide at the next drain; the watchdog tick always asks for a
        /// rebuild so cached deadlines and pause flips refresh within one
        /// tick interval.
        fn handleH2DataWaitResult(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            result: data_io.Result,
        ) bool {
            switch (result) {
                .wake => {
                    drainH2Wake(engine.h2_wake_fd);
                    return false;
                },
                .tick => return true,
                .expired => |context| {
                    const watch = readinessWatch(context);
                    if (watch.h1) |h1_item| {
                        expireH1Pending(engine, h1_item);
                        return true;
                    }
                    if (watch.pending) |expired| {
                        expireH2Pending(engine, pool, pending, data_driver, expired, engine.wake_ctx, engine.wake_fn.?);
                    } else {
                        _ = removeH2EntryIfLifecycleExpired(pool, data_driver, watch.entry.?, data_io.monotonicNowNs() catch std.math.maxInt(u64));
                    }
                    return true;
                },
                .failed => |failure| {
                    const watch = readinessWatch(failure.context);
                    if (watch.h1) |h1_item| {
                        failH1PendingByPtr(engine, h1_item, failure.err);
                        return true;
                    }
                    if (isSendHalfCloseError(failure.err)) {
                        if (watch.entry.?.bioTls()) |bio| {
                            // The peer closed before reading our trailing
                            // writes (final window updates race its FIN/RST).
                            // Its responses may already sit in our buffers
                            // and can still complete every pending stream:
                            // stop writing, keep reading until EOF, and let
                            // truncation fail only what it never sent.
                            bio.markSendBroken();
                            watch.entry.?.h2.closeWithoutPeerGoaway();
                            handleH2EntryReady(engine, pool, pending, connecting, data_driver, watch.entry.?, engine.wake_ctx, engine.wake_fn.?);
                            return true;
                        }
                    }
                    failH2PendingForEntry(engine, pool, pending, watch.entry.?, failure.err, engine.wake_ctx, engine.wake_fn.?);
                    removeH2Entry(pool, data_driver, watch.entry.?);
                    return true;
                },
                .ready => |ready| {
                    const watch = readinessWatch(ready.context);
                    if (watch.h1) |h1_item| {
                        // The pending's own drive pass performs the actual
                        // (nonblocking) syscalls; readiness just unparks it.
                        h1_item.park = .runnable;
                        return true;
                    }
                    if (ready.writable and watch.entry.?.hasOutgoing()) {
                        watch.entry.?.flushOutgoing() catch |err| {
                            failH2PendingForEntry(engine, pool, pending, watch.entry.?, err, engine.wake_ctx, engine.wake_fn.?);
                            removeH2Entry(pool, data_driver, watch.entry.?);
                            return true;
                        };
                    }
                    if (ready.readable) {
                        if (watch.pending != null)
                            handleH2EntryReady(engine, pool, pending, connecting, data_driver, watch.entry.?, engine.wake_ctx, engine.wake_fn.?)
                        else
                            handleH2IdleEntryReady(pool, data_driver, watch.entry.?);
                    }
                    return true;
                },
            }
        }

        fn isSendHalfCloseError(err: anyerror) bool {
            return err == error.BrokenPipe or
                err == error.ConnectionResetByPeer or
                err == error.FetchWriteFailed;
        }

        /// Transport-death errors safe to retry on a fresh connection when
        /// the failed request rode a reused session and saw no response
        /// bytes (the undici and Bun stale-connection rule). Errors caused by
        /// the response itself are excluded, because a retry would fetch the
        /// same poisonous response again.
        fn isH2StaleReuseError(err: anyerror) bool {
            return err == error.BrokenPipe or
                err == error.ConnectionResetByPeer or
                err == error.FetchWriteFailed or
                err == error.FetchResponseTruncated;
        }

        /// True when the stream failure carries the server's explicit
        /// guarantee that the request was never processed, making it safe to
        /// replay regardless of method or session reuse.
        fn isH2NotProcessedError(err: anyerror) bool {
            return err == error.Http2StreamRefused or
                err == error.Http2StreamNotProcessed;
        }

        fn h2RetryEligibleCommand(command: Command) bool {
            return command.h2_retries < max_h2_stream_retries and !command.task.isCanceled();
        }

        /// Gate for retry classes without the server's not-processed
        /// guarantee (dead reused session, entry write failure): part of the
        /// request may already have reached the server, so only idempotent
        /// bodyless requests replay, the same rule as the HTTP/1 pooled
        /// retry.
        fn isH2IdempotentReplayable(command: Command) bool {
            if (command.task.body.len != 0)
                return false;
            const method = command.task.method;
            return std.ascii.eqlIgnoreCase(method, "GET") or
                std.ascii.eqlIgnoreCase(method, "HEAD") or
                std.ascii.eqlIgnoreCase(method, "OPTIONS") or
                std.ascii.eqlIgnoreCase(method, "DELETE");
        }

        /// Move a command onto the owner's retry scratch instead of failing
        /// its fetch; resubmitted by drainH2Retries in the same iteration.
        /// Holds a task reference across the hop.
        fn queueH2RetryCommand(engine: *Engine, command: Command) void {
            var retried = command;
            retried.h2_retries += 1;
            retried.task.retain();
            engine.h2_retry_commands.append(engine.allocator, retried) catch {
                publishFailure(retried.task, error.OutOfMemory, engine.wake_ctx, engine.wake_fn.?);
                retried.task.release();
            };
        }

        /// Returns true when any command was resubmitted (watch-relevant
        /// mutation). Resubmission may queue further retries (e.g. an
        /// entry_failed on the next candidate entry); the loop drains those
        /// too, bounded by the per-command retry budget.
        fn drainH2Retries(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
        ) bool {
            var any = false;
            while (engine.h2_retry_commands.pop()) |command| {
                any = true;
                startH2Command(engine, pool, pending, connecting, data_driver, command);
                command.task.release();
            }
            return any;
        }

        fn failH2RetryCommands(engine: *Engine, err: anyerror) void {
            while (engine.h2_retry_commands.pop()) |command| {
                if (command.task.isCanceled())
                    completeCanceled(command.task, engine.wake_ctx, engine.wake_fn.?)
                else
                    publishFailure(command.task, err, engine.wake_ctx, engine.wake_fn.?);
                command.task.release();
            }
        }

        /// Parks a command that found every pool slot occupied. It waits for
        /// capacity instead of failing, bounded by its own deadline, which is
        /// fixed at the first park and kept across re-parks so sustained
        /// saturation (dirty iterations more frequent than socket_timeout)
        /// cannot renew it forever.
        fn queueH2PoolWaiter(engine: *Engine, command: Command) void {
            var parked = command;
            const deadline_mono_ns = parked.h2PoolParkDeadline(parked.config.capDeadlineMonoNs(
                readiness.deadlineAfterMs(parked.config.socket_timeout_ms) catch std.math.maxInt(u64),
            ));
            parked.task.retain();
            engine.h2_pool_waiters.append(engine.allocator, .{
                .command = parked,
                .deadline_mono_ns = deadline_mono_ns,
            }) catch {
                publishFailure(parked.task, error.Http2PoolExhausted, engine.wake_ctx, engine.wake_fn.?);
                parked.task.release();
            };
        }

        /// One resubmission pass over the parked commands. Runs on
        /// watch-dirty iterations, which cover every event that can free
        /// capacity (entry removal, stream completion). A command that still
        /// finds no room re-parks at the back; the pass budget keeps that
        /// from looping.
        fn drainH2PoolWaiters(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
        ) bool {
            var budget = engine.h2_pool_waiters.items.len;
            var any = false;
            while (budget > 0 and engine.h2_pool_waiters.items.len != 0) : (budget -= 1) {
                const waiter = engine.h2_pool_waiters.orderedRemove(0);
                startH2Command(engine, pool, pending, connecting, data_driver, waiter.command);
                waiter.command.task.release();
                any = true;
            }
            return any;
        }

        fn expireH2PoolWaiters(engine: *Engine, now_ns: u64) void {
            var index: usize = 0;
            while (index < engine.h2_pool_waiters.items.len) {
                const waiter = engine.h2_pool_waiters.items[index];
                if (waiter.command.task.isCanceled()) {
                    completeCanceled(waiter.command.task, engine.wake_ctx, engine.wake_fn.?);
                } else if (now_ns >= waiter.deadline_mono_ns or
                    waiter.command.config.requestDeadlineExpiredAt(now_ns))
                {
                    publishFailure(waiter.command.task, error.Http2PoolExhausted, engine.wake_ctx, engine.wake_fn.?);
                } else {
                    index += 1;
                    continue;
                }
                _ = engine.h2_pool_waiters.orderedRemove(index);
                waiter.command.task.release();
            }
        }

        fn failH2PoolWaiters(engine: *Engine, err: anyerror) void {
            while (engine.h2_pool_waiters.pop()) |waiter| {
                if (waiter.command.task.isCanceled())
                    completeCanceled(waiter.command.task, engine.wake_ctx, engine.wake_fn.?)
                else
                    publishFailure(waiter.command.task, err, engine.wake_ctx, engine.wake_fn.?);
                waiter.command.task.release();
            }
        }

        fn handleH2IdleEntryReady(pool: *pool_mod.Pool, data_driver: *data_io.Driver, entry: *pool_mod.Entry) void {
            var completion = pool.readEntryEvent(entry) catch |err| {
                if (err == error.Http2WouldBlock) {
                    _ = removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
                    return;
                }
                removeH2Entry(pool, data_driver, entry);
                return;
            };
            completion.deinit();
            removeH2Entry(pool, data_driver, entry);
        }

        fn readinessWatch(context: *anyopaque) *H2Watch {
            return @ptrCast(@alignCast(context));
        }

        /// Returns true when any pending was canceled (watch-relevant
        /// mutation: the caller must rebuild the watch list).
        fn cancelH2Pending(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) bool {
            var canceled_any = false;
            var index: usize = 0;
            while (index < pending.items.len) {
                const item = pending.items[index];
                if (item.headers_published) {
                    if (!item.body.isCanceled()) {
                        index += 1;
                        continue;
                    }
                    canceled_any = true;
                    const entry = item.stream.entry;
                    pool.cancelStream(item.stream) catch |err| {
                        var removed = pending.orderedRemove(index);
                        defer removed.deinit(pool.allocator);
                        // Abort bills what was delivered up to the cancel.
                        foldH2PendingMetersIntoBody(&removed);
                        failH2PendingForEntry(engine, pool, pending, entry, err, wake_ctx, wake_fn);
                        removeH2Entry(pool, data_driver, entry);
                        continue;
                    };
                    var removed = pending.orderedRemove(index);
                    defer removed.deinit(pool.allocator);
                    // Abort bills what was delivered up to the cancel.
                    foldH2PendingMetersIntoBody(&removed);
                    _ = removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
                    continue;
                }
                if (!item.command.task.isCanceled()) {
                    index += 1;
                    continue;
                }
                canceled_any = true;
                const entry = item.stream.entry;
                pool.cancelStream(item.stream) catch |err| {
                    var removed = pending.orderedRemove(index);
                    defer removed.deinit(pool.allocator);
                    completeCanceled(removed.command.task, wake_ctx, wake_fn);
                    failH2PendingForEntry(engine, pool, pending, entry, err, wake_ctx, wake_fn);
                    removeH2Entry(pool, data_driver, entry);
                    continue;
                };
                var removed = pending.orderedRemove(index);
                defer removed.deinit(pool.allocator);
                completeCanceled(removed.command.task, wake_ctx, wake_fn);
                _ = removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
            }
            return canceled_any;
        }

        fn failAllH2Pending(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            err: anyerror,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) void {
            while (pending.items.len != 0) {
                const entry = pending.items[0].stream.entry;
                failH2PendingForEntry(engine, pool, pending, entry, err, wake_ctx, wake_fn);
                removeH2Entry(pool, data_driver, entry);
            }
        }

        /// Teardown for when the driver can no longer watch or wait, shared
        /// by the watch build, sync and wait failure handlers. It settles
        /// every pending of both protocols: h2 first, which also removes the
        /// entries hosting them, then h1, where failAllH1Pending settles the
        /// exchange and continuation state and skips connector-held
        /// `.awaiting_connect` pendings, which settle through the connector's
        /// completion delivery. It then drops the idle pooled entries nothing
        /// can watch anymore, which would otherwise hold the idle guard open
        /// and spin the loop against the broken driver, and disarms every
        /// persistent fd poll with an empty desired set. The disarm is safe
        /// without the kernel round trip: syncSources retires the arm tokens
        /// in userspace before touching the ring, so even when the flush
        /// fails a late completion can only be dropped, never delivered into
        /// a freed pending.
        fn failAllOwnerWork(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            err: anyerror,
        ) void {
            failAllH2Pending(engine, pool, pending, data_driver, err, engine.wake_ctx, engine.wake_fn.?);
            failAllH1Pending(engine, err);
            while (pool.entries.items.len != 0)
                removeH2Entry(pool, data_driver, pool.entries.items[0]);
            data_driver.syncSources(&.{}) catch |sync_err|
                std.log.debug("egress owner catastrophe disarm flush failed: {s}", .{@errorName(sync_err)});
        }

        /// Test seam for the fatal-error handlers: test builds can inject a
        /// watch-build, sync or data-wait failure without a broken allocator
        /// or a dead ring. Compiles to nothing outside test builds.
        fn takeInjectedOwnerFault(engine: *Engine, comptime field_name: []const u8) ?anyerror {
            if (!builtin.is_test)
                return null;
            const raw = @field(engine, field_name).swap(0, .acq_rel);
            if (raw == 0)
                return null;
            return @errorFromInt(raw);
        }

        fn failH2PendingForEntry(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            entry: *pool_mod.Entry,
            err: anyerror,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) void {
            var index: usize = 0;
            while (index < pending.items.len) {
                var item = pending.items[index];
                if (item.stream.entry != entry) {
                    index += 1;
                    continue;
                }
                item = pending.orderedRemove(index);
                defer item.deinit(pool.allocator);
                if (item.headers_published) {
                    foldH2PendingMetersIntoBody(&item);
                    failFetchBodyBestEffort(item.body, pool.allocator, @errorName(err), "h2 entry failure");
                    wake_fn(wake_ctx, .{ .task_ready = item.command.readyToken() });
                } else if (item.command.task.isCanceled()) {
                    completeCanceled(item.command.task, wake_ctx, wake_fn);
                } else if ((isH2NotProcessedError(err) or
                    (item.stream.reused and isH2StaleReuseError(err) and
                        isH2IdempotentReplayable(item.command))) and
                    h2RetryEligibleCommand(item.command))
                {
                    // A failed attempt counts as cost only: the client never
                    // asked for the retry, so its billed bytes are dropped.
                    item.command.task.addEgressBase(0, 0, item.cost_bytes);
                    queueH2RetryCommand(engine, item.command);
                } else {
                    // Failure bills what was delivered: the fold carries the
                    // billed pair into the body meters, which are the only
                    // failure carrier.
                    foldH2PendingMetersIntoBody(&item);
                    publishFailure(item.command.task, err, wake_ctx, wake_fn);
                }
            }
        }

        fn expireH2Pending(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            expired: *const H2Pending,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) void {
            const stream = expired.stream;
            const now_ns = readiness.monotonicNowNs() catch expired.effectiveDeadlineMonoNs();
            const timeout_err = expired.expiredErrorAt(now_ns);
            const pending_index = findH2PendingIndex(pending.items, stream.entry, stream.stream_id) orelse return;
            pool.cancelStream(stream) catch |err| {
                var item = pending.orderedRemove(pending_index);
                defer item.deinit(pool.allocator);
                if (item.headers_published) {
                    foldH2PendingMetersIntoBody(&item);
                    failFetchBodyBestEffort(item.body, pool.allocator, @errorName(timeout_err), "h2 cancel timeout fallback");
                    wake_fn(wake_ctx, .{ .task_ready = item.command.readyToken() });
                } else if (item.command.task.isCanceled()) {
                    completeCanceled(item.command.task, wake_ctx, wake_fn);
                } else {
                    publishFailure(item.command.task, timeout_err, wake_ctx, wake_fn);
                }
                failH2PendingForEntry(engine, pool, pending, stream.entry, err, wake_ctx, wake_fn);
                removeH2Entry(pool, data_driver, stream.entry);
                return;
            };
            var item = pending.orderedRemove(pending_index);
            defer item.deinit(pool.allocator);
            if (item.headers_published) {
                foldH2PendingMetersIntoBody(&item);
                failFetchBodyBestEffort(item.body, pool.allocator, @errorName(timeout_err), "h2 timeout");
                wake_fn(wake_ctx, .{ .task_ready = item.command.readyToken() });
            } else if (item.command.task.isCanceled()) {
                completeCanceled(item.command.task, wake_ctx, wake_fn);
            } else {
                publishFailure(item.command.task, timeout_err, wake_ctx, wake_fn);
            }
            _ = removeH2EntryIfClosingAndIdle(pool, data_driver, stream.entry);
        }

        fn handleH2EntryReady(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) void {
            // One recv burst can park events for several streams (or HEADERS
            // plus DATA plus END_STREAM of a single one) in the session
            // queue. Bytes already consumed off the socket never produce
            // another readability wake, so any event left queued here would
            // stall its fetch forever. Drain until the session reports
            // would-block; the peer cannot extend the loop indefinitely
            // because draining grants no new flow-control credit.
            while (drainOneH2EntryEvent(engine, pool, pending, connecting, data_driver, entry, wake_ctx, wake_fn) == .more) {}
        }

        const H2EntryDrainStep = enum {
            /// Event consumed and the entry survived; more events may be queued.
            more,
            /// Event queue drained, or the entry was removed.
            stop,
        };

        fn drainOneH2EntryEvent(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) H2EntryDrainStep {
            var completion = pool.readEntryEvent(entry) catch |err| {
                if (err == error.Http2WouldBlock)
                    return .stop;
                failH2PendingForEntry(engine, pool, pending, entry, err, wake_ctx, wake_fn);
                removeH2Entry(pool, data_driver, entry);
                return .stop;
            };

            switch (completion) {
                .head => |*head| {
                    defer completion.deinit();
                    const pending_index = findH2PendingIndex(pending.items, entry, head.stream_id) orelse {
                        failH2PendingForEntry(engine, pool, pending, entry, error.Http2UnknownStream, wake_ctx, wake_fn);
                        removeH2Entry(pool, data_driver, entry);
                        return .stop;
                    };
                    var item = &pending.items[pending_index];
                    item.addCostBytes(head.result.wire_bytes.total());
                    // The final response header block is billed; 1xx blocks
                    // never carry billed_head_bytes.
                    item.billed_bytes.addReceived(@intCast(head.billed_head_bytes));
                    foldH2PendingMetersIntoBody(item);
                    // Origin progress: the response head arrived, so restart
                    // the stall clock for the body phase.
                    refreshH2StallDeadline(item);
                    if (item.headers_published)
                        return .more;
                    if (item.command.task.isCanceled()) {
                        pool.cancelStream(item.stream) catch |err| {
                            failH2PendingForEntry(engine, pool, pending, entry, err, wake_ctx, wake_fn);
                            removeH2Entry(pool, data_driver, entry);
                            return .stop;
                        };
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        completeCanceled(removed.command.task, wake_ctx, wake_fn);
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    }
                    const maybe_redirect = transport.redirectTarget(
                        pool.allocator,
                        item.command.task.url,
                        item.command.task.method,
                        item.command.task.headers,
                        item.command.task.body,
                        head.result.status_code,
                        head.result.headers,
                        .{
                            .redirect_mode = transport.RedirectMode.fromFlags(item.command.task.flags),
                            .max_redirects = item.command.config.max_redirects,
                        },
                        item.command.task.redirect_count,
                    ) catch |err| {
                        cancelH2StreamBestEffort(pool, item.stream, "redirect validation failure");
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        publishFailure(removed.command.task, err, wake_ctx, wake_fn);
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    };
                    if (maybe_redirect) |redirect| {
                        return if (followH2RedirectFromHead(
                            engine,
                            pool,
                            pending,
                            connecting,
                            data_driver,
                            entry,
                            pending_index,
                            redirect,
                            wake_ctx,
                            wake_fn,
                        )) .more else .stop;
                    }

                    const response_encoding = decompress.encodingFromHeaders(head.result.headers) catch |err| {
                        cancelH2StreamBestEffort(pool, item.stream, "response encoding failure");
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        publishFailure(removed.command.task, err, wake_ctx, wake_fn);
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    };
                    const pump_limits = item.command.config.streamPumpLimitsForEncoding(response_encoding).normalized() catch |err| {
                        cancelH2StreamBestEffort(pool, item.stream, "response body limits failure");
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        publishFailure(removed.command.task, err, wake_ctx, wake_fn);
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    };
                    item.body_sink = .{ .max_encoded_bytes = pump_limits.max_encoded_bytes };

                    const result_allocator = item.command.task.resultAllocator();
                    const owned_url = result_allocator.dupe(u8, item.command.task.url) catch |err| {
                        cancelH2StreamBestEffort(pool, item.stream, "response url clone failure");
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        publishFailure(removed.command.task, err, wake_ctx, wake_fn);
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    };
                    const headers = task_model.cloneBindResponseHeaders(result_allocator, head.result.headers) catch |err| {
                        cancelH2StreamBestEffort(pool, item.stream, "response header clone failure");
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        publishFailure(removed.command.task, err, wake_ctx, wake_fn);
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    };
                    item.headers_published = true;
                    publishResult(item.command.task, .{ .success = .{
                        .status = head.result.status_code,
                        .url = owned_url,
                        .body_identity = item.command.task.response_body_identity,
                        .headers = headers,
                        .redirected = item.command.task.redirect_count != 0,
                        .body_encoding = response_encoding,
                    } }, wake_ctx, wake_fn);
                    if (head.result.end_stream) {
                        // A stream that ends at HEADERS never queues DATA
                        // credit, so no body-credit ack will ever surface its
                        // deferred `.end`; ack zero credit now to release it.
                        return if (ackH2ZeroCreditAndComplete(engine, pool, pending, data_driver, entry, head.stream_id, wake_ctx, wake_fn)) .more else .stop;
                    }
                    return .more;
                },
                .progress => |progress| {
                    defer completion.deinit();
                    const pending_index = findH2PendingIndex(pending.items, entry, progress.stream_id) orelse {
                        failH2PendingForEntry(engine, pool, pending, entry, error.Http2UnknownStream, wake_ctx, wake_fn);
                        removeH2Entry(pool, data_driver, entry);
                        return .stop;
                    };
                    var item = &pending.items[pending_index];
                    // 1xx blocks are cost, never billed.
                    item.addCostBytes(progress.wire_bytes.total());
                    foldH2PendingMetersIntoBody(item);
                    // An interim (1xx) response is origin progress: restart the
                    // stall clock so a 103 Early Hints followed by a slow final
                    // head is not judged as origin silence. The total request
                    // deadline still bounds an origin stalling behind 1xx spam.
                    refreshH2StallDeadline(item);
                    return .more;
                },
                .body_chunk => |*body_event| {
                    const pending_index = findH2PendingIndex(pending.items, entry, body_event.stream_id) orelse {
                        completion.deinit();
                        failH2PendingForEntry(engine, pool, pending, entry, error.Http2UnknownStream, wake_ctx, wake_fn);
                        removeH2Entry(pool, data_driver, entry);
                        return .stop;
                    };
                    var item = &pending.items[pending_index];
                    item.addCostBytes(body_event.wire_bytes.total());
                    // DATA payload (padding already stripped by the codec) is
                    // the billed unit for response bodies.
                    item.billed_bytes.addReceived(body_event.bytes.len);
                    foldH2PendingMetersIntoBody(item);
                    // Origin progress: a body chunk arrived, so restart the
                    // stall clock. A long download that keeps progressing is
                    // not killed by the idle timeout; only a silence of
                    // socket_timeout_ms fires FetchReadTimeout.
                    refreshH2StallDeadline(item);
                    if (!item.headers_published) {
                        completion.deinit();
                        ackH2DataBestEffort(pool, entry, body_event.stream_id, body_event.flow_credit, false, "body before headers");
                        failH2PendingForEntry(engine, pool, pending, entry, error.Http2ProtocolError, wake_ctx, wake_fn);
                        removeH2Entry(pool, data_driver, entry);
                        return .stop;
                    }
                    if (item.command.task.isCanceled()) {
                        completion.deinit();
                        ackH2DataBestEffort(pool, entry, body_event.stream_id, body_event.flow_credit, false, "canceled body");
                        cancelH2StreamBestEffort(pool, item.stream, "canceled body");
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        failFetchBodyBestEffort(removed.body, pool.allocator, @errorName(error.FetchAborted), "canceled body");
                        wake_fn(wake_ctx, .{ .task_ready = removed.command.readyToken() });
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    }

                    const owned_chunk = body_event.bytes;
                    body_event.bytes = &.{};
                    defer completion.deinit();
                    const ready_waiter = item.body_sink.appendH2DataOwned(
                        pool.allocator,
                        item.body,
                        item.credit_source_id,
                        body_event.stream_id,
                        owned_chunk,
                        body_event.flow_credit,
                        body_event.update_stream_window,
                    ) catch |err| {
                        ackH2DataBestEffort(pool, entry, body_event.stream_id, body_event.flow_credit, false, "body sink append failure");
                        cancelH2StreamBestEffort(pool, item.stream, "body sink append failure");
                        var removed = pending.orderedRemove(pending_index);
                        defer removed.deinit(pool.allocator);
                        failFetchBodyBestEffort(removed.body, pool.allocator, @errorName(err), "body sink append failure");
                        wake_fn(wake_ctx, .{ .task_ready = removed.command.readyToken() });
                        return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                    };
                    item.unacked_h2_credit +|= body_event.flow_credit;
                    // The origin is done: stop the stall clock so the completed
                    // response is not judged silent while the consumer drains
                    // the last (possibly zero-credit) frame and acks the end.
                    if (body_event.end_stream)
                        item.origin_finished = true;
                    if (ready_waiter)
                        wake_fn(wake_ctx, .{ .task_ready = item.command.readyToken() });
                    return .more;
                },
                .end => |*end| {
                    defer completion.deinit();
                    return if (completeH2BodyFromEnd(engine, pool, pending, data_driver, entry, end.stream_id, end.wire_bytes.total(), end.billed_bytes, wake_ctx, wake_fn)) .more else .stop;
                },
                .failure => |failure| {
                    const pending_index = findH2PendingIndex(pending.items, entry, failure.stream_id) orelse {
                        failH2PendingForEntry(engine, pool, pending, entry, error.Http2UnknownStream, wake_ctx, wake_fn);
                        removeH2Entry(pool, data_driver, entry);
                        return .stop;
                    };
                    var item = pending.orderedRemove(pending_index);
                    defer item.deinit(pool.allocator);
                    item.addCostBytes(failure.wire_bytes.total());
                    item.mergeCumulativeBilled(failure.billed_bytes);
                    if (item.headers_published) {
                        foldH2PendingMetersIntoBody(&item);
                        failFetchBodyBestEffort(item.body, pool.allocator, @errorName(failure.err), "h2 stream failure");
                        wake_fn(wake_ctx, .{ .task_ready = item.command.readyToken() });
                    } else if (item.command.task.isCanceled()) {
                        completeCanceled(item.command.task, wake_ctx, wake_fn);
                    } else if (isH2NotProcessedError(failure.err) and h2RetryEligibleCommand(item.command)) {
                        // REFUSED_STREAM, or a GOAWAY that excludes this
                        // stream: the server guarantees the request never
                        // ran. The failed attempt's bytes count as cost only;
                        // the client never asked for the retry, so nothing is
                        // billed.
                        item.command.task.addEgressBase(0, 0, item.cost_bytes);
                        queueH2RetryCommand(engine, item.command);
                    } else {
                        // Failure bills what was delivered: the fold carries
                        // the billed pair into the body meters, which are the
                        // only failure carrier.
                        foldH2PendingMetersIntoBody(&item);
                        publishFailure(item.command.task, failure.err, wake_ctx, wake_fn);
                    }
                    return if (removeH2EntryIfClosingAndIdle(pool, data_driver, entry)) .stop else .more;
                },
            }
        }

        /// Returns true when the credit surfaced an end, failed the entry, or
        /// changed pump or body state, anything the cached watch list could
        /// be stale about. A plain ack that only releases window credit (the
        /// common case under the update threshold) returns false: sends are
        /// armed from live connection state, so no rebuild is needed.
        fn applyH2BodyCredit(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            credit: body_credit.H2Data,
        ) bool {
            const pending_index = findH2PendingIndexByBodyCredit(pending.items, credit) orelse return false;
            const entry = pending.items[pending_index].stream.entry;
            // The consumer acked this credit, so it is no longer in its
            // hands. The pause flip this can cause (deadline from maxInt to a
            // real value) leaves the cached watch list stale only in the
            // harmless direction, and the watchdog tick heals it. Acks may
            // arrive aggregated: the gateway sums the encoded_bytes of several
            // consumed chunks of one stream into one message. The invariant
            // is therefore conservation of the sum: every appended chunk's
            // encoded_bytes enters unacked_h2_credit exactly once and is
            // acked exactly once, alone or inside an aggregate, so any ack is
            // bounded by the running unacked total. Debug builds assert it;
            // release builds saturate.
            std.debug.assert(credit.encoded_bytes <= pending.items[pending_index].unacked_h2_credit);
            pending.items[pending_index].unacked_h2_credit -|= credit.encoded_bytes;
            // A zero-credit ack (empty final DATA frame) writes no window
            // updates but must still run: the deferred `.end` of a stream
            // whose credit is fully released is only surfaced here.
            var maybe_end = pool.ackReceivedData(entry, credit.stream_id, credit.encoded_bytes, credit.update_stream_window) catch |err| {
                failH2PendingForEntry(engine, pool, pending, entry, err, engine.wake_ctx, engine.wake_fn.?);
                removeH2Entry(pool, data_driver, entry);
                return true;
            };
            var mutated = false;
            if (maybe_end) |*end_event| {
                defer end_event.deinit();
                mutated = true;
                switch (end_event.*) {
                    .end => |end| {
                        if (!completeH2BodyFromEnd(engine, pool, pending, data_driver, entry, end.stream_id, end.wire_bytes.total(), end.billed_bytes, engine.wake_ctx, engine.wake_fn.?))
                            return true;
                    },
                    else => {
                        failH2PendingForEntry(engine, pool, pending, entry, error.Http2ProtocolError, engine.wake_ctx, engine.wake_fn.?);
                        removeH2Entry(pool, data_driver, entry);
                        return true;
                    },
                }
            } else {
                // No terminal event: the consumer released credit. If it has
                // now caught up, the engine is waiting on the origin again,
                // so restart the stall clock from now. During backpressure
                // the origin was blocked on the engine's flow control, and a
                // deadline frozen at the last chunk would treat a slow
                // consumer as an origin silence and fail the transfer with
                // FetchReadTimeout. This moves the deadline, so the watch list
                // must rebuild.
                var item = &pending.items[pending_index];
                if (!item.stallClockSuspended()) {
                    refreshH2StallDeadline(item);
                    mutated = true;
                }
            }
            return mutated;
        }

        /// Returns true when the entry is still alive after the redirect
        /// handoff.
        fn followH2RedirectFromHead(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
            pending_index: usize,
            redirect: transport.RedirectTarget,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) bool {
            defer freeRedirectTarget(pool.allocator, redirect);

            const stream = pending.items[pending_index].stream;
            pool.cancelStream(stream) catch |err| {
                failH2PendingForEntry(engine, pool, pending, entry, err, wake_ctx, wake_fn);
                removeH2Entry(pool, data_driver, entry);
                return false;
            };

            var item = pending.orderedRemove(pending_index);
            defer item.deinit(pool.allocator);
            // The client asked for the chain, so this hop's billed and cost
            // bytes both fold into the task's cross-hop base. The next hop's
            // pending starts at zero and reports base+attempt absolutes, so
            // nothing is lost to the monotonic-max fold when this pending
            // dies below.
            item.command.task.addEgressBase(
                item.billed_bytes.sent,
                item.billed_bytes.received,
                item.cost_bytes,
            );
            item.command.task.replaceRequest(
                redirect.url,
                redirect.method,
                redirect.body,
                redirect.headers,
            ) catch |err| {
                publishFailure(item.command.task, err, wake_ctx, wake_fn);
                return !removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
            };
            item.command.task.redirect_count += 1;

            startH2Command(engine, pool, pending, connecting, data_driver, item.command);
            // A same-origin redirect routes back through this entry, and
            // startH2Command removes it on open failure; only touch the
            // entry if it is still pooled.
            for (pool.entries.items) |candidate| {
                if (candidate == entry)
                    return !removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
            }
            return false;
        }

        fn freeRedirectTarget(allocator: std.mem.Allocator, redirect: transport.RedirectTarget) void {
            allocator.free(redirect.url);
            allocator.free(redirect.method);
            transport.freeHeaders(allocator, redirect.headers);
        }

        fn applyH2BodyCancel(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            identity: bindings.FetchBodyIdentity,
        ) void {
            const pending_index = findH2PendingIndexByBodyIdentity(pending.items, identity) orelse return;
            var item = pending.items[pending_index];
            const entry = item.stream.entry;
            pool.cancelStream(item.stream) catch |err| {
                failH2PendingForEntry(engine, pool, pending, entry, err, engine.wake_ctx, engine.wake_fn.?);
                removeH2Entry(pool, data_driver, entry);
                return;
            };
            item = pending.orderedRemove(pending_index);
            defer item.deinit(pool.allocator);
            // Abort bills what was delivered up to the cancel: fold the last
            // known meters so the gateway's terminal error carries them.
            foldH2PendingMetersIntoBody(&item);
            failFetchBodyBestEffort(item.body, pool.allocator, @errorName(error.FetchAborted), "h2 body cancel");
            engine.wake_fn.?(engine.wake_ctx, .{ .task_ready = item.command.readyToken() });
            _ = removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
        }

        /// Surfaces the deferred `.end` of a stream that will never receive a
        /// non-zero body-credit ack (response ended at HEADERS). Returns true
        /// when the entry is still alive.
        fn ackH2ZeroCreditAndComplete(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
            stream_id: u32,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) bool {
            var maybe_end = pool.ackReceivedData(entry, stream_id, 0, false) catch |err| {
                failH2PendingForEntry(engine, pool, pending, entry, err, wake_ctx, wake_fn);
                removeH2Entry(pool, data_driver, entry);
                return false;
            };
            if (maybe_end) |*end_event| {
                defer end_event.deinit();
                switch (end_event.*) {
                    .end => |end| return completeH2BodyFromEnd(engine, pool, pending, data_driver, entry, end.stream_id, end.wire_bytes.total(), end.billed_bytes, wake_ctx, wake_fn),
                    else => {
                        failH2PendingForEntry(engine, pool, pending, entry, error.Http2ProtocolError, wake_ctx, wake_fn);
                        removeH2Entry(pool, data_driver, entry);
                        return false;
                    },
                }
            }
            return true;
        }

        /// Returns true when the entry is still alive after the end-of-stream
        /// completion.
        fn completeH2BodyFromEnd(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
            stream_id: u32,
            wire_bytes: u64,
            billed_bytes: accounting.Bytes,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) bool {
            const pending_index = findH2PendingIndex(pending.items, entry, stream_id) orelse {
                failH2PendingForEntry(engine, pool, pending, entry, error.Http2UnknownStream, wake_ctx, wake_fn);
                removeH2Entry(pool, data_driver, entry);
                return false;
            };
            var item = &pending.items[pending_index];
            item.addCostBytes(wire_bytes);
            // The terminal event carries the codec's cumulative billed
            // counter, the only one that sees trailers and window-driven
            // upload writes after open.
            item.mergeCumulativeBilled(billed_bytes);
            if (!item.headers_published) {
                var removed = pending.orderedRemove(pending_index);
                defer removed.deinit(pool.allocator);
                publishFailure(removed.command.task, error.FetchResultMissing, wake_ctx, wake_fn);
                return !removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
            }
            foldH2PendingMetersIntoBody(item);
            item.end_stream_seen = true;
            _ = tryCompleteH2BodyAt(pool, pending, pending_index, wake_ctx, wake_fn);
            return !removeH2EntryIfClosingAndIdle(pool, data_driver, entry);
        }

        fn tryCompleteH2BodyAt(
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            pending_index: usize,
            wake_ctx: ?*anyopaque,
            wake_fn: WakeFn,
        ) bool {
            if (pending_index >= pending.items.len)
                return false;
            var item = &pending.items[pending_index];
            if (!item.end_stream_seen)
                return false;
            // The engine ships bytes as received (no decode stage), so end
            // of stream completes the body immediately; trailing decoder
            // state is the consumer's concern.
            const ready = item.body.complete();
            if (ready)
                wake_fn(wake_ctx, .{ .task_ready = item.command.readyToken() });
            var removed = pending.orderedRemove(pending_index);
            removed.deinit(pool.allocator);
            return true;
        }
        fn publishH2StartFailure(engine: *Engine, command: Command, err: anyerror) void {
            switch (err) {
                error.Http2AlpnNotNegotiated,
                error.Http2UnsupportedScheme,
                => {
                    http1_pool.rememberOrigin(engine, command);
                    startH1Command(engine, command);
                },
                error.Http2PoolExhausted => queueH2PoolWaiter(engine, command),
                else => publishFailure(command.task, err, engine.wake_ctx, engine.wake_fn.?),
            }
        }

        // ------------------------------------------------------------------
        // HTTP/1 on the owner loop: pendings drive the transport exchange and
        // body continuations with nonblocking syscalls, parking on the shared
        // watch list; connector threads only dial.
        // ------------------------------------------------------------------

        /// Protocol routing for a fresh or requeued command: HTTP/2 for https
        /// origins not known to speak only HTTP/1, owner-loop HTTP/1 for
        /// everything else.
        fn startAnyCommand(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            command: Command,
        ) void {
            if (http1_pool.shouldUseHttp2Owner(engine, command))
                startH2Command(engine, pool, pending, connecting, data_driver, command)
            else
                startH1Command(engine, command);
        }

        fn startH1Command(engine: *Engine, command: Command) void {
            const wake_ctx = engine.wake_ctx;
            const wake_fn = engine.wake_fn.?;
            if (command.task.isCanceled()) {
                completeCanceled(command.task, wake_ctx, wake_fn);
                return;
            }
            const source_id = http1_pool.nextResumeSourceId(engine);
            const base = command.task.egressBase();
            const ready_token = command.task.readyToken();
            const exchange = transport.Http1Exchange.init(
                engine.allocator,
                &engine.http1_shared_pool.?,
                command.task.url,
                command.task.method,
                command.task.body,
                command.task.headers,
                command.config,
                .{
                    .redirect_mode = transport.RedirectMode.fromFlags(command.task.flags),
                    .max_redirects = command.config.max_redirects,
                },
                command.task.redirect_count,
                .{
                    .billed_sent = base.billed_sent,
                    .billed_received = base.billed_received,
                    .cost = base.cost,
                },
                source_id,
                command.task.response_body,
                engine,
                http1_pool.wakeBodyGeneric,
                .{ .token = .{ .ptr = command.task, .generation = ready_token.generation } },
            ) catch |err| {
                publishFailure(command.task, err, wake_ctx, wake_fn);
                return;
            };
            var pending_item = H1Pending.init(command, exchange, source_id);
            engine.h1_pending.append(engine.allocator, pending_item) catch {
                exchange.deinit();
                publishFailure(pending_item.command.task, error.OutOfMemory, wake_ctx, wake_fn);
                pending_item.deinit(engine.allocator);
            };
        }

        /// True when any h1 pending needs the owner's drive/watch machinery
        /// (anything but a connector-held `.awaiting_connect` wait).
        fn hasOwnerDrivenH1Work(engine: *Engine) bool {
            for (engine.h1_pending.items) |*item| {
                if (item.park != .awaiting_connect)
                    return true;
            }
            return false;
        }

        fn h1TaskCanceled(ctx: ?*anyopaque) bool {
            const task: *task_model.Task = @ptrCast(@alignCast(ctx orelse return false));
            return task.isCanceled();
        }

        fn h1CancelProbe(
            item: *H1Pending,
            park_info: *transport.CancelProbe.WouldBlock,
        ) transport.CancelProbe {
            return .{
                .ctx = item.command.task,
                .is_canceled_fn = h1TaskCanceled,
                .would_block = park_info,
                .request_deadline_mono_ns = item.command.config.request_deadline_mono_ns,
            };
        }

        /// Parks on socket readiness with a fresh stall window: every park
        /// gets socket_timeout_ms, capped by the total request deadline, so a
        /// long transfer that keeps progressing keeps renewing it and only an
        /// origin silence fires.
        fn parkH1Io(
            item: *H1Pending,
            fd: std.posix.fd_t,
            interest: transport.IoInterest,
            timeout_err: anyerror,
            abandon_reuse_on_expire: bool,
        ) void {
            const now_ns = readiness.monotonicNowNs() catch std.math.maxInt(u64);
            item.park = .{ .io = .{
                .fd = fd,
                .interest = interest,
                .timeout_err = timeout_err,
                .deadline_mono_ns = item.command.config.stallDeadlineFromNow(now_ns),
                .abandon_reuse_on_expire = abandon_reuse_on_expire,
            } };
        }

        /// Steps every runnable h1 pending until it parks, completes, leaves
        /// for the h2 path, or exhausts a fairness budget. Every event that
        /// makes a pending runnable marks the watch list dirty, so running
        /// this inside the dirty block covers all of them before the next
        /// wait. The whole pass is also bounded by the per-turn budget
        /// (`H1TurnBudget`, which documents the fairness contract): once it
        /// runs out, the remaining runnables wait for the next turn. Returns
        /// true when runnable work was left behind, because a pending
        /// yielded its per-drive quantum or the turn budget ran out with a
        /// runnable still waiting. Runnable pendings have no watch source,
        /// so the caller must arrange an immediate follow-up pass (self-wake
        /// and dirty) instead of letting the wait sleep on them.
        fn driveRunnableH1(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
        ) bool {
            var turn_budget = H1TurnBudget{};
            var more_runnable = false;
            // The pass is bounded by the runnable set observed at its start:
            // every runnable gets at most one quantum per pass, and the yield
            // rotation only sets the next pass's order. Without this bound
            // two yielding runnables would alternate within one pass (A
            // yields and rotates to the back while the index stays put, B is
            // driven, yields and rotates, A is driven again) until only the
            // turn budget ended the cycle, spending a whole turn on the same
            // pair and leaving a stale more_runnable self-wake behind.
            var drives_left: usize = 0;
            for (engine.h1_pending.items) |*item| {
                if (item.park == .runnable)
                    drives_left += 1;
            }
            var drives_used: usize = 0;
            // Only yielded drives prove the streaming regime. A drive that
            // only dispatched a connect or parked on io counts into
            // drives_used but says nothing about body streaming, so the
            // per-pass maximum the fairness tests check counts yields
            // separately.
            var yields_used: usize = 0;
            defer engine.h2_stats.recordH1PassDrives(drives_used);
            defer engine.h2_stats.recordH1PassYields(yields_used);
            var index: usize = 0;
            while (drives_left != 0 and index < engine.h1_pending.items.len) {
                if (engine.h1_pending.items[index].park != .runnable) {
                    index += 1;
                    continue;
                }
                // Gate before the drive: the found pending stays runnable, so
                // exhaustion here leaves runnable work by construction and
                // counts as a budget-cut pass, one that drained the whole turn
                // budget with work still waiting.
                if (!turn_budget.admitDrive()) {
                    engine.h2_stats.countH1TurnBudgetExhausted();
                    return true;
                }
                drives_left -= 1;
                drives_used += 1;
                var drive_budget = transport.Http1DriveBudget{};
                const drive_bytes_before = drive_budget.bytes_left;
                const outcome = driveOneH1(engine, pool, pending, connecting, data_driver, index, &drive_budget);
                switch (outcome) {
                    .kept => index += 1,
                    // The list shifted (or the same slot now holds another
                    // pending); re-examine the same index.
                    .removed => {},
                    // Round-robin across passes as well as within one: the
                    // yielder stays runnable but rotates to the back of the
                    // pending list, so it earns its next quantum only after
                    // every other runnable ran, including the ones an
                    // exhausted turn budget leaves out of this pass. Each
                    // pass restarts at index 0; without the rotation, a burst
                    // wider than one turn budget (16 bulk quanta reach the
                    // 4 MiB byte cap) would re-serve the same head-of-list
                    // pendings on every self-wake while the tail got neither
                    // service nor a deadline source.
                    .yielded, .yielded_retry => {
                        // Only body-quantum yields prove streaming; the
                        // dial-retry fallback for a failed clock read yields
                        // again without streaming progress.
                        if (outcome == .yielded)
                            yields_used += 1;
                        more_runnable = true;
                        const last_index = engine.h1_pending.items.len - 1;
                        if (index < last_index) {
                            const yielder = engine.h1_pending.orderedRemove(index);
                            // Capacity is untouched by orderedRemove, so the
                            // re-append cannot fail or move the list.
                            engine.h1_pending.appendAssumeCapacity(yielder);
                            // The same slot now holds the next pending;
                            // re-examine this index.
                        } else {
                            // Already at the back; the pass is done with it.
                            index += 1;
                        }
                    },
                }
                turn_budget.chargeDrained(drive_bytes_before - drive_budget.bytes_left);
            }
            // Rotated yielders already set the flag; this sweep catches any
            // runnable the start-count bound left undriven. Drives never
            // create new runnables, but the self-wake contract (true exactly
            // when runnable work remains) must hold regardless.
            if (!more_runnable) {
                for (engine.h1_pending.items) |*item| {
                    if (item.park == .runnable) {
                        more_runnable = true;
                        break;
                    }
                }
            }
            return more_runnable;
        }

        // `yielded_retry` is the dial-retry fallback for a failed clock read:
        // it keeps the pending runnable (self-wake retry) and rotates like a
        // yield, but proves no streaming progress, so it must not count into
        // the per-pass yield stat the fairness tests check.
        const H1DriveOutcome = enum { kept, removed, yielded, yielded_retry };

        /// `budget` is one fairness quantum for this whole drive, owned by
        /// the caller so the turn budget can meter what it consumed, and
        /// shared across the transition from exchange to body and across
        /// redirect hops within the drive. Only the body continuation, which
        /// could otherwise consume a whole fast response in one sitting,
        /// draws from it; the exchange side is already bounded per hop
        /// (response heads by limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX,
        /// redirect drains by max_redirect_drain_bytes, hops by
        /// max_redirects, uploads by the request-body policy cap).
        fn driveOneH1(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            index: usize,
            budget: *transport.Http1DriveBudget,
        ) H1DriveOutcome {
            while (true) {
                // Re-fetched every round: publish/redirect handling below can
                // reallocate the pending list.
                const item = &engine.h1_pending.items[index];
                switch (item.phase) {
                    .exchange => |exchange| {
                        var park_info = transport.CancelProbe.WouldBlock{};
                        const need = exchange.drive(h1CancelProbe(item, &park_info)) catch |err| {
                            failH1PendingAt(engine, index, err);
                            return .removed;
                        };
                        switch (need) {
                            .io => |io| {
                                const fd = exchange.connectionFd() orelse {
                                    failH1PendingAt(engine, index, error.FetchWriteFailed);
                                    return .removed;
                                };
                                parkH1Io(item, fd, io.interest, io.timeout_err, io.on_expire == .abandon_reuse);
                                return .kept;
                            },
                            .connect => {
                                var connect_command = item.command;
                                connect_command.h1_connect = true;
                                engine.enqueueH2Connect(connect_command) catch |err| switch (err) {
                                    // Connector-queue pressure is transient
                                    // and must not fail the fetch; a redirect
                                    // hop can land here mid-flight. Park on a
                                    // short retry tick, a deadline-only watch
                                    // source whose expiry makes the pending
                                    // runnable again; the drive pass then
                                    // re-emits `.connect` (the exchange stays
                                    // in awaiting_connect) and retries the
                                    // dispatch. A runnable self-wake retry
                                    // would make no progress while the queue
                                    // stays full and re-run the owner's whole
                                    // dirty pass (cancel sweeps, watch
                                    // rebuild, driver sync) as a busy loop,
                                    // endless for fetches without a request
                                    // deadline. The park is bounded like
                                    // every other wait: its deadline is
                                    // capped by the total request deadline,
                                    // whose expiry fails the fetch here and
                                    // in expireH1Pending.
                                    error.EgressEngineQueueFull => {
                                        // Without a readable clock neither
                                        // the expiry check nor a finite park
                                        // deadline can be computed: a
                                        // saturated `now` would pass every
                                        // finite deadline check and fail the
                                        // fetch as expired, and a maxInt
                                        // park builds no watch source and
                                        // would strand the pending. Keep the
                                        // runnable self-wake retry for this
                                        // edge only.
                                        const now_ns = readiness.monotonicNowNs() catch return .yielded_retry;
                                        if (item.command.config.requestDeadlineExpiredAt(now_ns)) {
                                            failH1PendingAt(engine, index, item.expiredErrorAt(now_ns));
                                            return .removed;
                                        }
                                        item.park = .{ .dial_retry = .{
                                            .deadline_mono_ns = item.dialRetryParkDeadline(now_ns),
                                        } };
                                        return .kept;
                                    },
                                    else => {
                                        failH1PendingAt(engine, index, err);
                                        return .removed;
                                    },
                                };
                                item.park = .awaiting_connect;
                                return .kept;
                            },
                            .publish_head => |head| {
                                publishH1Head(engine, item, head) catch |err| {
                                    failH1PendingAt(engine, index, err);
                                    return .removed;
                                };
                                item.headers_published = true;
                                exchange.markPublished();
                                continue;
                            },
                            .redirect => |redirect| {
                                switch (followH1Redirect(engine, pool, pending, connecting, data_driver, index, redirect)) {
                                    .kept => continue,
                                    .removed => return .removed,
                                    // Redirect handoff never draws on the
                                    // drive budget; only body steps yield,
                                    // and it never touches the dial path.
                                    .yielded, .yielded_retry => unreachable,
                                }
                            },
                            .body => |continuation| {
                                // The body continuation owns the connection
                                // now, so the exchange can go.
                                exchange.deinit();
                                item.phase = .{ .body = continuation };
                                continue;
                            },
                            .done => {
                                // Headers were published and the exchange
                                // settled the body inline without waking
                                // anyone, so the task is woken here.
                                exchange.deinit();
                                var finished = engine.h1_pending.orderedRemove(index);
                                engine.wake_fn.?(engine.wake_ctx, .{ .task_ready = finished.command.readyToken() });
                                finished.deinit(engine.allocator);
                                return .removed;
                            },
                        }
                    },
                    .body => |continuation| {
                        var park_info = transport.CancelProbe.WouldBlock{};
                        const step = continuation.step(h1CancelProbe(item, &park_info), budget) catch |err| {
                            if (err == error.EgressWouldBlock) {
                                parkH1Io(item, continuation.connection.fd(), park_info.interest, park_info.timeout_err, false);
                                return .kept;
                            }
                            var failed = engine.h1_pending.orderedRemove(index);
                            continuation.failAndDeinit(@errorName(err));
                            failed.deinit(engine.allocator);
                            return .removed;
                        };
                        switch (step) {
                            .done => {
                                continuation.foldMetersIntoBody();
                                continuation.ready_fn(continuation.ready_ctx, continuation.ready_event);
                                continuation.returnConnectionIfReusable();
                                continuation.deinit();
                                var finished = engine.h1_pending.orderedRemove(index);
                                finished.deinit(engine.allocator);
                                return .removed;
                            },
                            .paused => {
                                // Consumer backpressure: the h1 resume credit
                                // attached by the capacity-exhausting append
                                // is the wake (stall clock suspended, total
                                // request deadline still applies).
                                item.park = .credit;
                                return .kept;
                            },
                            // Fairness quantum exhausted: the pending stays
                            // runnable, with no deadline to arm because it is
                            // not waiting on io, and the drive pass moves on
                            // to the next runnable instead of re-driving it
                            // here.
                            .yielded => return .yielded,
                        }
                    },
                }
            }
        }

        /// One h1 redirect hop ended: fold the hop's meters into the task's
        /// cross-hop base (the client asked for the chain), replace the
        /// request, and route the restart like a fresh submit. An https
        /// target whose origin is not known to be HTTP/1 goes to the h2 path;
        /// everything else gets a fresh h1 exchange on the same pending.
        fn followH1Redirect(
            engine: *Engine,
            pool: *pool_mod.Pool,
            pending: *std.array_list.Aligned(H2Pending, null),
            connecting: *std.array_list.Aligned(H2ConnectGroup, null),
            data_driver: *data_io.Driver,
            index: usize,
            redirect: transport.RedirectTarget,
        ) H1DriveOutcome {
            const item = &engine.h1_pending.items[index];
            const exchange = item.phase.exchange;
            const billed = exchange.hopBilled();
            item.command.task.addEgressBase(billed.sent, billed.received, exchange.hopCost());
            const replace_failed: ?anyerror = blk: {
                item.command.task.replaceRequest(
                    redirect.url,
                    redirect.method,
                    redirect.body,
                    redirect.headers,
                ) catch |err| break :blk err;
                break :blk null;
            };
            freeRedirectTarget(engine.allocator, redirect);
            if (replace_failed) |err| {
                failH1PendingAt(engine, index, err);
                return .removed;
            }
            item.command.task.redirect_count += 1;

            if (http1_pool.shouldUseHttp2Owner(engine, item.command)) {
                exchange.deinit();
                var moved = engine.h1_pending.orderedRemove(index);
                startH2Command(engine, pool, pending, connecting, data_driver, moved.command);
                moved.deinit(engine.allocator);
                return .removed;
            }

            // Build the next hop's exchange before releasing the old one so a
            // failure still settles through a live phase pointer.
            const base = item.command.task.egressBase();
            const ready_token = item.command.task.readyToken();
            const next_exchange = transport.Http1Exchange.init(
                engine.allocator,
                &engine.http1_shared_pool.?,
                item.command.task.url,
                item.command.task.method,
                item.command.task.body,
                item.command.task.headers,
                item.command.config,
                .{
                    .redirect_mode = transport.RedirectMode.fromFlags(item.command.task.flags),
                    .max_redirects = item.command.config.max_redirects,
                },
                item.command.task.redirect_count,
                .{
                    .billed_sent = base.billed_sent,
                    .billed_received = base.billed_received,
                    .cost = base.cost,
                },
                item.source_id,
                item.body_pipe,
                engine,
                http1_pool.wakeBodyGeneric,
                .{ .token = .{ .ptr = item.command.task, .generation = ready_token.generation } },
            ) catch |err| {
                failH1PendingAt(engine, index, err);
                return .removed;
            };
            exchange.deinit();
            item.phase = .{ .exchange = next_exchange };
            item.park = .runnable;
            return .kept;
        }

        fn publishH1Head(engine: *Engine, item: *H1Pending, head: *const transport.StreamedResponseHead) !void {
            const task = item.command.task;
            const allocator = task.resultAllocator();
            const status_text = try allocator.dupe(u8, head.status_text);
            const url = try allocator.dupe(u8, head.url);
            const headers = try task_model.cloneBindResponseHeaders(allocator, head.headers);
            publishResult(task, .{ .success = .{
                .status = head.status,
                .status_text = status_text,
                .url = url,
                .body_identity = task.response_body_identity,
                .headers = headers,
                .redirected = head.redirected,
            } }, engine.wake_ctx, engine.wake_fn.?);
        }

        /// Cancel sweep for h1 pendings, run on dirty iterations like the h2
        /// scan: a cancel before publication settles the task as canceled,
        /// and one after publication fails the body. Connector-held pendings
        /// are skipped, because the connector always publishes an outcome and
        /// the cancel completes there, as with HTTP/2 connect groups.
        fn cancelH1Pending(engine: *Engine) void {
            var index: usize = 0;
            while (index < engine.h1_pending.items.len) {
                const item = &engine.h1_pending.items[index];
                if (item.park == .awaiting_connect) {
                    index += 1;
                    continue;
                }
                const canceled = if (item.headers_published)
                    item.body_pipe.isCanceled() or item.command.task.isCanceled()
                else
                    item.command.task.isCanceled();
                if (!canceled) {
                    index += 1;
                    continue;
                }
                failH1PendingAt(engine, index, error.FetchAborted);
            }
        }

        /// A consumer released decoded capacity. Only credit-parked pendings
        /// react. Anything else means the release raced ahead of a pause that
        /// never happened, and every later pause comes from an append that
        /// exhausts capacity and attaches its own credit (`resumeCreditFor`
        /// in core/stream_pump.zig), so dropping this release cannot lose a
        /// wake.
        fn applyH1Resume(engine: *Engine, source_id: u64) bool {
            for (engine.h1_pending.items) |*item| {
                if (item.source_id != source_id)
                    continue;
                if (item.park == .credit) {
                    item.park = .runnable;
                    return true;
                }
                return false;
            }
            return false;
        }

        fn applyH1BodyCancel(engine: *Engine, identity: bindings.FetchBodyIdentity) void {
            for (engine.h1_pending.items, 0..) |*item, index| {
                if (item.body_pipe.identity.request_id != identity.request_id or
                    item.body_pipe.identity.request_generation != identity.request_generation or
                    item.body_pipe.identity.fetch_id != identity.fetch_id or
                    item.body_pipe.identity.body_id != identity.body_id)
                    continue;
                if (item.park == .awaiting_connect)
                    return;
                failH1PendingAt(engine, index, error.FetchAborted);
                return;
            }
        }

        fn applyH1Connected(engine: *Engine, connected: H1Connected) void {
            var message = connected;
            const index = findH1AwaitingConnect(engine, message.command.task) orelse {
                // The pending died first, in a race with engine stop; only the
                // wire needs teardown.
                switch (message.outcome) {
                    .wire => |*wire| wire.deinit(),
                    .failure => {},
                }
                return;
            };
            switch (message.outcome) {
                .failure => |err| failH1PendingAt(engine, index, err),
                .wire => |wire| {
                    const item = &engine.h1_pending.items[index];
                    item.phase.exchange.adoptConnection(wire);
                    item.park = .runnable;
                },
            }
        }

        fn findH1AwaitingConnect(engine: *Engine, task: *task_model.Task) ?usize {
            for (engine.h1_pending.items, 0..) |*item, index| {
                if (item.park == .awaiting_connect and item.command.task == task)
                    return index;
            }
            return null;
        }

        fn h1PendingIndexOf(engine: *Engine, item: *H1Pending) ?usize {
            for (engine.h1_pending.items, 0..) |*candidate, index| {
                if (candidate == item)
                    return index;
            }
            return null;
        }

        fn failH1PendingByPtr(engine: *Engine, item: *H1Pending, err: anyerror) void {
            const index = h1PendingIndexOf(engine, item) orelse return;
            failH1PendingAt(engine, index, err);
        }

        fn failH1PendingAt(engine: *Engine, index: usize, err: anyerror) void {
            var item = engine.h1_pending.orderedRemove(index);
            settleFailedH1(engine, &item, err);
            item.deinit(engine.allocator);
        }

        fn settleFailedH1(engine: *Engine, item: *H1Pending, err: anyerror) void {
            const wake_ctx = engine.wake_ctx;
            const wake_fn = engine.wake_fn.?;
            switch (item.phase) {
                .exchange => |exchange| {
                    const published = item.headers_published;
                    // Failure bills what was delivered: fold the exchange's
                    // base+attempt meters into the body pipe before the
                    // exchange dies, as foldH2PendingMetersIntoBody does for
                    // h2, because the body meters are the only failure
                    // carrier. Without it a failure before the response head
                    // (origin stalled after the upload, dead write, timeout)
                    // would publish zero meters although part of the request
                    // already crossed the wire.
                    exchange.settleFailureMeters();
                    exchange.deinit();
                    if (published) {
                        // A failure after publication settles the body; the
                        // task result is already out.
                        failFetchBodyBestEffort(item.body_pipe, engine.allocator, @errorName(err), "h1 exchange failure");
                        wake_fn(wake_ctx, .{ .task_ready = item.command.readyToken() });
                    } else if (item.command.task.isCanceled()) {
                        // A cancel also bills what was delivered: the fold
                        // above carried the meters into the body pipe, and
                        // completeCanceled itself publishes no byte total.
                        completeCanceled(item.command.task, wake_ctx, wake_fn);
                    } else {
                        publishFailure(item.command.task, err, wake_ctx, wake_fn);
                    }
                },
                // failAndDeinit folds the continuation's meters (billed equals
                // delivered), publishes the body failure, and wakes through the
                // continuation's own ready event.
                .body => |continuation| continuation.failAndDeinit(@errorName(err)),
            }
        }

        /// An h1 watch deadline fired. A redirect-drain park only abandons
        /// connection reuse, because the drain exists only to keep the
        /// connection reusable; anything else fails with the park's stage
        /// error, or the request-deadline error when the total clock is what
        /// ran out.
        fn expireH1Pending(engine: *Engine, item: *H1Pending) void {
            const now_ns = readiness.monotonicNowNs() catch std.math.maxInt(u64);
            switch (item.park) {
                .io => |io| {
                    if (io.abandon_reuse_on_expire and !item.command.config.requestDeadlineExpiredAt(now_ns)) {
                        switch (item.phase) {
                            .exchange => |exchange| exchange.abandonRedirectDrain(),
                            .body => {},
                        }
                        item.park = .runnable;
                        return;
                    }
                    failH1PendingByPtr(engine, item, item.expiredErrorAt(now_ns));
                },
                .credit => failH1PendingByPtr(engine, item, item.expiredErrorAt(now_ns)),
                // A queue-full dial park's retry tick fired: back to runnable,
                // so the next drive pass re-emits `.connect` and retries the
                // dispatch (the `.expired` result already marks the watch
                // dirty, which runs that pass before the next wait), unless
                // the total request deadline is what ran out.
                .dial_retry => {
                    if (item.command.config.requestDeadlineExpiredAt(now_ns)) {
                        failH1PendingByPtr(engine, item, item.expiredErrorAt(now_ns));
                        return;
                    }
                    item.park = .runnable;
                },
                // Stale watch entry (park changed since the build); the dirty
                // rebuild re-evaluates.
                .awaiting_connect, .runnable => {},
            }
        }

        /// Owner-exit settlement for h1 pendings. `.awaiting_connect`
        /// pendings are skipped, as h2 connect groups skip their dispatched
        /// command: their h1_connect command is in the connector pipeline
        /// (the park is set only after a successful dispatch, and only
        /// applyH1Connected clears it), and the connector dereferences
        /// command.task throughout its dial (cancel probe, request plan).
        /// Settling here would let the gateway drop the fetch's last
        /// reference, and this pending's deinit drop the last task retain,
        /// while the dial still runs. A skipped pending settles exactly once
        /// through the connector's completion delivery instead:
        /// applyH1Connected while the owner loop still runs, or, after every
        /// thread parked, drainQueuesOnStop (queued outcome, never-popped
        /// command, or the refused-handoff leftover sweep).
        fn failAllH1Pending(engine: *Engine, err: anyerror) void {
            var index: usize = engine.h1_pending.items.len;
            while (index != 0) {
                index -= 1;
                if (engine.h1_pending.items[index].park == .awaiting_connect)
                    continue;
                failH1PendingAt(engine, index, err);
            }
        }

        /// Stop-path settlement for one connector-held h1 pending that the
        /// exit sweep skipped: settles the `.awaiting_connect` pending owned
        /// by `task` and releases it. Callable only with every engine thread
        /// parked (drainQueuesOnStop), when the connector's last task
        /// dereference is over and h1_pending has a single owner again.
        pub fn settleStoppedH1ConnectPendingByTask(
            engine: *Engine,
            task: *task_model.Task,
            err: anyerror,
        ) void {
            const index = findH1AwaitingConnect(engine, task) orelse return;
            failH1PendingAt(engine, index, err);
        }

        /// Stop-path leftover sweep. An `.awaiting_connect` pending still
        /// alive after the stop drains consumed every queued outcome and
        /// never-popped command is a refused handoff: its connector saw stop
        /// refuse the completion enqueue and tore down only the wire, because
        /// it must never touch owner state. With every thread parked, this is
        /// the last completion-delivery path left, so settle them here,
        /// exactly once.
        pub fn settleStoppedH1ConnectPendings(engine: *Engine, err: anyerror) void {
            var index: usize = engine.h1_pending.items.len;
            while (index != 0) {
                index -= 1;
                if (engine.h1_pending.items[index].park != .awaiting_connect)
                    continue;
                failH1PendingAt(engine, index, err);
            }
        }

        /// Connector-thread HTTP/1 dial for a pool miss or a replay: the
        /// blocking DNS, TCP and TLS work runs here, off the owner thread,
        /// and the nonblocking connection is published back to the owner.
        /// Every dispatched dial publishes an outcome, or its pending would
        /// wait forever, as in completeH2Connect.
        fn completeH1Connect(
            engine: *Engine,
            command: Command,
            readiness_driver: *readiness.Driver,
        ) void {
            if (command.task.isCanceled()) {
                publishH1Connected(engine, .{ .command = command, .outcome = .{ .failure = error.FetchAborted } });
                return;
            }
            var plan = transport.prepareRequest(
                engine.allocator,
                command.task.url,
                command.task.method,
                command.task.headers,
                command.config,
            ) catch |err| {
                publishH1Connected(engine, .{ .command = command, .outcome = .{ .failure = err } });
                return;
            };
            defer plan.deinit();
            const policy = transport.EgressPolicy{
                .allow_plain_http = command.config.allow_plain_http,
                .allow_private_networks = command.config.allow_private_networks,
            };
            var target = policy.resolveRequestTargetUntil(
                engine.allocator,
                &engine.dns_cache,
                plan.target,
                command.config.request_deadline_mono_ns,
            ) catch |err| {
                publishH1Connected(engine, .{ .command = command, .outcome = .{ .failure = err } });
                return;
            };
            defer target.deinit(engine.allocator);
            const probe = transport.CancelProbe{
                .ctx = command.task,
                .is_canceled_fn = h1TaskCanceled,
                .driver = readiness_driver,
                .request_deadline_mono_ns = command.config.request_deadline_mono_ns,
            };
            const connection = transport.connectWithProbe(engine.allocator, target, command.config, probe) catch |err| {
                engine.dns_cache.invalidate(plan.target.tls_server_name, plan.target.port);
                publishH1Connected(engine, .{ .command = command, .outcome = .{ .failure = err } });
                return;
            };
            publishH1Connected(engine, .{ .command = command, .outcome = .{ .wire = connection } });
        }

        fn publishH1Connected(engine: *Engine, connected: H1Connected) void {
            var message = connected;
            H2Queue.enqueueH2MessageBlocking(engine, .{ .h1_connected = message }) catch |err| {
                switch (message.outcome) {
                    .wire => |*wire| wire.deinit(),
                    .failure => {},
                }
                // Stop refused the handoff. Tear down only the wire and
                // settle nothing here: the pending is owner state, the owner
                // thread may still be running because the threads leave a
                // stopping run in no fixed order, and the owner's exit sweep
                // skips it as connector-held. drainQueuesOnStop's leftover
                // sweep is this dial's completion delivery and settles the
                // pending after every thread parked, exactly once.
                if (err != error.EgressEngineStopped)
                    std.debug.panic("HTTP/1 connector completion handoff failed: {s}", .{@errorName(err)});
            };
        }
    };
}
