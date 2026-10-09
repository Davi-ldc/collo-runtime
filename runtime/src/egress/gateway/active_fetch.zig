//! One fetch a shard engine has admitted, as its active table (`active_table.zig`) holds it: the
//! request whose egress token admitted it, the transport task, the response body, how far
//! publication to the worker has gone, and the body-pool extents the worker still holds. Also the
//! worker-scoped identity that tables and routes key on, and the batching of flow-control credits
//! on their way back to the engine.
//!
//! Only the gateway's loop thread touches a `Fetch`. Engine threads share its task, which they
//! reference-count and guard with the task's own mutex, so `deinit` releases the task instead of
//! destroying it. Every flow-control credit a body chunk carries goes back to the engine at most
//! once: released right away, recorded against the pool extent that published it and released
//! when the worker returns that extent, or released when queued chunks are discarded. An extent
//! the worker returns after its failed or canceled fetch has retired finds no route, and its
//! credit is dropped, since the stream it would refill is gone (`runtime/body_release_flow.zig`).
//! A credit the engine refuses detaches the whole worker session
//! (`Engine.reportWorkerCreditReleaseFailure`).

const std = @import("std");
const ipc = @import("collo_ipc");
const egress = @import("collo_egress_client");
const os_process = @import("collo_os").process;

const budgets = @import("budgets.zig");

const body_credit = egress.body_credit;
const fetch_body = egress.fetch_body;
const task_model = egress.task;

/// A fetch named the way its worker names it. Fetch and body ids are chosen by the worker and are
/// unique only within its session, so every lookup carries the session id as well.
pub const WorkerScopedFetch = struct {
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,

    pub fn matchesFetch(self: WorkerScopedFetch, worker_session_id: u64, fetch_id: u64) bool {
        return self.worker_session_id == worker_session_id and self.fetch_id == fetch_id;
    }

    pub fn matchesBody(
        self: WorkerScopedFetch,
        worker_session_id: u64,
        fetch_id: u64,
        body_id: u64,
    ) bool {
        return self.matchesFetch(worker_session_id, fetch_id) and self.body_id == body_id;
    }
};

pub const BodyChunkPayload = struct {
    bytes: []const u8,
    /// The fetch's cumulative meters when the chunk is published (`Fetch.egressMeters`). The
    /// worker keeps the largest value it has seen of each, so a repeated total changes nothing.
    billed_sent_total: u64 = 0,
    billed_received_total: u64 = 0,
    cost_total: u64 = 0,
    /// The engine flow-control credit these bytes carry. The publisher records it against the
    /// last pool extent the chunk lands in, and the gateway releases it to the engine when the
    /// worker returns that extent, so the worker's release is the credit acknowledgement.
    credit: body_credit.Handle = .none,
};

/// Credits released to one engine during one drain or release pass, merged so that a burst of
/// consumed chunks costs one engine message, and one wake of the engine's owner thread, per
/// stream instead of one per chunk. HTTP/2 credits merge when source, stream and
/// `update_stream_window` all match, summing `encoded_bytes`, and travel as one
/// `body_credit.H2Data`. The engine asserts that a stream never has more bytes acknowledged than
/// it holds as unacknowledged credit (`unacked_h2_credit`), which a merged credit respects because
/// each of its parts was recorded against the stream once. A zero-byte credit, from the empty
/// final DATA frame that surfaces a deferred end of stream, keeps its own slot and so still
/// produces a message. HTTP/1 resume credits deduplicate by source: a source has at most one
/// resume outstanding, since every later pause comes from a new append that exhausts capacity and
/// attaches its own credit, and the engine ignores a resume whose pending request is not parked
/// on credit (`applyH1Resume`).
///
/// A full table flushes before it takes another credit, so batching never fails.
pub const CreditBatch = struct {
    pub const h2_slot_count = 8;
    pub const h1_slot_count = 4;

    const H2Slot = struct {
        source_id: u64,
        stream_id: u32,
        encoded_bytes: usize,
        update_stream_window: bool,
    };

    h2: [h2_slot_count]H2Slot = undefined,
    h2_len: usize = 0,
    h1: [h1_slot_count]u64 = undefined,
    h1_len: usize = 0,

    pub fn add(
        self: *CreditBatch,
        engine: anytype,
        worker_session_id: u64,
        credit: body_credit.Handle,
    ) void {
        switch (credit) {
            .none => {},
            .h1_resume => |h1| {
                for (self.h1[0..self.h1_len]) |source_id| {
                    if (source_id == h1.source_id)
                        return;
                }
                if (self.h1_len == self.h1.len)
                    self.flush(engine, worker_session_id);
                self.h1[self.h1_len] = h1.source_id;
                self.h1_len += 1;
            },
            .h2_data => |h2| {
                for (self.h2[0..self.h2_len]) |*slot| {
                    // The codec clears update_stream_window only on a stream's
                    // END_STREAM frame. Folding that credit into a slot whose
                    // flag is set would add the final frame's bytes to the
                    // stream receive window and send WINDOW_UPDATE for a stream
                    // the peer has closed. A stream has one such credit, so
                    // keeping it apart costs at most one extra slot.
                    if (slot.source_id == h2.source_id and
                        slot.stream_id == h2.stream_id and
                        slot.update_stream_window == h2.update_stream_window)
                    {
                        slot.encoded_bytes +|= h2.encoded_bytes;
                        return;
                    }
                }
                if (self.h2_len == self.h2.len)
                    self.flush(engine, worker_session_id);
                self.h2[self.h2_len] = .{
                    .source_id = h2.source_id,
                    .stream_id = h2.stream_id,
                    .encoded_bytes = h2.encoded_bytes,
                    .update_stream_window = h2.update_stream_window,
                };
                self.h2_len += 1;
            },
        }
    }

    pub fn flush(self: *CreditBatch, engine: anytype, worker_session_id: u64) void {
        for (self.h2[0..self.h2_len]) |slot| {
            const credit = body_credit.h2Data(
                slot.source_id,
                slot.stream_id,
                slot.encoded_bytes,
                slot.update_stream_window,
            );
            engine.releaseCredit(credit) catch |err| {
                engine.reportWorkerCreditReleaseFailure(worker_session_id, credit, err);
            };
        }
        self.h2_len = 0;
        for (self.h1[0..self.h1_len]) |source_id| {
            const credit = body_credit.h1Resume(source_id);
            engine.releaseCredit(credit) catch |err| {
                engine.reportWorkerCreditReleaseFailure(worker_session_id, credit, err);
            };
        }
        self.h1_len = 0;
    }
};

pub const Fetch = struct {
    worker_session_id: u64,
    /// The request whose egress token admitted the fetch; `request_ended` cancels the fetch by it
    /// (`Engine.cancelRequest`), and a redispatch after a shard restart keeps it
    /// (`engine.ReplayFetch`).
    budget_key: budgets.BudgetKey,
    worker_attached: bool,
    task: *task_model.Task,
    body: *fetch_body.Body,
    fetch_id: u64,
    body_id: u64,
    head_sent: bool = false,
    terminal: bool = false,
    body_end_sent: bool = false,
    pull_armed: bool = false,
    /// The fetch's cumulative meters, summed from the deltas `egressMeters` takes out of the
    /// body, so no delta is counted twice.
    egress_meters_total: fetch_body.EgressMeters = .{},
    /// Body-pool extents published for this fetch that the worker has not returned yet. A fetch
    /// that sent body end keeps its place in the active table, and with it its route and
    /// admission counts, until this reaches zero; the last returned extent retires it
    /// (`Engine.noteExtentReleasedAndMaybeRetire`). A fetch that fails, or is canceled even after
    /// body end, retires as soon as its task settles, and the release path drops the credits of
    /// its late extents (`runtime/body_release_flow.zig`).
    outstanding_extents: usize = 0,
    /// The request's absolute monotonic deadline from admission, the deadline of its token, or 0
    /// for none. A fetch redispatched after its shard restarts keeps this deadline
    /// (`engine.ReplayFetch`), so a restart never gives a request more time.
    request_deadline_mono_ns: u64 = 0,

    pub fn matchesFetch(self: Fetch, worker_session_id: u64, fetch_id: u64) bool {
        return self.scopedFetch().matchesFetch(worker_session_id, fetch_id);
    }

    pub fn matchesBody(self: Fetch, worker_session_id: u64, fetch_id: u64, body_id: u64) bool {
        return self.scopedFetch().matchesBody(worker_session_id, fetch_id, body_id);
    }

    pub fn scopedFetch(self: Fetch) WorkerScopedFetch {
        return .{
            .worker_session_id = self.worker_session_id,
            .fetch_id = self.fetch_id,
            .body_id = self.body_id,
        };
    }

    pub fn deinit(self: *Fetch, engine: anytype) void {
        self.releaseQueuedBodyCredits(engine);
        // Engine threads may still hold the task (parked body continuations,
        // h2 pendings); the last reference destroys it.
        self.task.release();
        self.* = undefined;
    }

    pub fn releaseQueuedBodyCredits(self: *Fetch, engine: anytype) void {
        const context = .{
            .engine = engine,
            .worker_session_id = self.worker_session_id,
        };
        const ReleaseContext = @TypeOf(context);
        const Callback = struct {
            fn release(release_context: ReleaseContext, credit: body_credit.Handle) void {
                release_context.engine.releaseCredit(credit) catch |err| {
                    release_context.engine.reportWorkerCreditReleaseFailure(
                        release_context.worker_session_id,
                        credit,
                        err,
                    );
                };
            }
        };
        self.body.releaseQueuedChunksCallback(engine.allocator, context, Callback.release);
    }

    /// Marks the fetch terminal and detached, so the worker gets no further packet for it,
    /// cancels its task and body, and releases the credits of chunks still queued. A caller whose
    /// engine is running then wakes its cancellation path (`wakeCancellation`).
    pub fn detachAndCancel(self: *Fetch, engine: anytype, message: []const u8) void {
        self.worker_attached = false;
        self.terminal = true;
        self.task.markCanceled();
        _ = self.body.cancel(engine.allocator, message, null) catch self.body.cancelNoAlloc();
        self.releaseQueuedBodyCredits(engine);
    }

    pub fn ensurePullArmed(self: *Fetch, engine: anytype) !void {
        if (self.pull_armed or self.terminal)
            return;
        if (engine.workerPressure(self.worker_session_id).pause_pulls)
            return;
        try self.armPull();
    }

    /// `ensurePullArmed` with worker pressure the caller already probed. The body drain probes
    /// once per iteration of its loop (`body_pump.drainBody`) and passes that result here.
    pub fn ensurePullArmedWithPressure(self: *Fetch, pressure: anytype) !void {
        if (self.pull_armed or self.terminal)
            return;
        if (pressure.pause_pulls)
            return;
        try self.armPull();
    }

    fn armPull(self: *Fetch) !void {
        self.pull_armed = true;
        if (try self.body.beginPull(.{ .deferred = null }))
            self.body.clearReadyQueued();
    }

    pub fn egressMeters(self: *Fetch) fetch_body.EgressMeters {
        const delta = self.body.takeUnaccountedEgressMeters();
        self.egress_meters_total.billed_sent +|= delta.billed_sent;
        self.egress_meters_total.billed_received +|= delta.billed_received;
        self.egress_meters_total.cost +|= delta.cost;
        return self.egress_meters_total;
    }

    pub fn taskDone(self: *Fetch) bool {
        self.task.mutex.lock();
        defer self.task.mutex.unlock();
        return self.task.done;
    }

    pub fn canRetire(self: *Fetch) bool {
        return self.terminal and self.taskDone();
    }

    pub fn sendBodyEnd(self: *Fetch, engine: anytype) !void {
        if (!self.worker_attached)
            return;
        const meters = self.egressMeters();
        const message = ipc.EgressBodyEnd{
            .kind = @intFromEnum(ipc.MessageKind.egress_body_end),
            .fetch_id = self.fetch_id,
            .body_id = self.body_id,
            .billed_sent_total = meters.billed_sent,
            .billed_received_total = meters.billed_received,
            .cost_total = meters.cost,
            .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
        };
        try self.sendPacketOrDetach(engine, std.mem.asBytes(&message));
    }

    pub fn sendError(
        self: *Fetch,
        engine: anytype,
        message: []const u8,
        meters: fetch_body.EgressMeters,
    ) !void {
        if (!self.worker_attached)
            return;
        const bytes = try ipc.encodeEgressFetchErrorInto(engine.scratch, .{
            .fetch_id = self.fetch_id,
            .body_id = self.body_id,
            .message = message,
            .billed_sent_total = meters.billed_sent,
            .billed_received_total = meters.billed_received,
            .cost_total = meters.cost,
            .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
        });
        try self.sendPacketOrDetach(engine, bytes);
    }

    pub fn sendBodyChunkBatchOrDetach(
        self: *Fetch,
        engine: anytype,
        chunks: []const BodyChunkPayload,
    ) !void {
        if (!self.worker_attached)
            return;
        const published = engine.sendBodyChunkBatch(
            self.worker_session_id,
            self.fetch_id,
            self.body_id,
            chunks,
        ) catch |err| switch (err) {
            error.PeerClosed, error.EgressGatewayWorkerBackpressure => {
                self.detachAndCancel(engine, "egress completion backpressure");
                engine.inner.wakeCancellation();
                return;
            },
            else => return err,
        };
        self.noteExtentsPublished(published);
    }

    /// Sends `bytes` to the worker. A gone worker or a full completion ring detaches and cancels
    /// the fetch instead of failing the call; any other publication error propagates.
    /// `sendBodyChunkBatchOrDetach` follows the same rule.
    pub fn sendPacketOrDetach(self: *Fetch, engine: anytype, bytes: []const u8) !void {
        if (!self.worker_attached)
            return;
        engine.sendPacket(self.worker_session_id, bytes) catch |err| switch (err) {
            error.PeerClosed, error.EgressGatewayWorkerBackpressure => {
                self.detachAndCancel(engine, "egress completion backpressure");
                engine.inner.wakeCancellation();
                return;
            },
            else => return err,
        };
    }

    pub fn releaseImmediateCredits(
        self: *Fetch,
        engine: anytype,
        credits: []const body_credit.Handle,
    ) void {
        var batch = CreditBatch{};
        for (credits) |credit|
            batch.add(engine, self.worker_session_id, credit);
        batch.flush(engine, self.worker_session_id);
    }

    pub fn noteExtentsPublished(self: *Fetch, count: usize) void {
        self.outstanding_extents += count;
    }

    /// Counts one pool extent the worker returned. The caller decides retirement from
    /// `body_end_sent` and `outstanding_extents` (`Engine.noteExtentReleasedAndMaybeRetire`).
    pub fn noteExtentReleased(self: *Fetch) void {
        self.outstanding_extents -|= 1;
    }
};
