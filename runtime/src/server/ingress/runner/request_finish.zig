//! The end of an ingress lane's requests and the worker slots they give back,
//! on the lane thread: the one finish of every request whatever ended it,
//! with its access record, its usage settle and the answer or reset its
//! stream gets, and the handoff of a freed worker slot to the next waiter.
//!
//! Invariants:
//! - A request finishes once and emits one access record. The lane writes
//!   the record's identity, duration and every status it synthesizes; a
//!   worker's completion supplies only its status, error code and the CPU,
//!   I/O and waiting times.
//! - A completion parked on a request means the worker answered, so the
//!   request ends with it whatever else ended it: a deadline, a death, a
//!   reset or the lane's shutdown.
//! - A dispatched request settles its usage and its request table entry
//!   (`Supervisor.settleRequest` in `server/supervisor/supervisor.zig`)
//!   before its worker slot goes back, so a worker never has more entries
//!   than slots. A request whose begin never reached the worker leaves no
//!   usage.
//! - A request that carried an egress token notes its end on the lane's
//!   lease (`Lease.noteEnded` in `server/gateway/lease.zig`). The loop sends
//!   the noted entries to the gateway at the end of the pass
//!   (`ring_driver.runQueuedWork`), which then drops each token's budget and
//!   cancels its fetches; a finish never waits for the gateway.
//! - A freed slot goes to the oldest waiter at once (`Pool.release` in
//!   `server/supervisor/pool.zig`): this lane's own waiter is dispatched on
//!   it here, another lane's gets `dispatch_ready`, and a worker the pool
//!   retires goes to the reaper (`queueRetirement`).
//! - Whether a response head went out is the lane's own HTTP/2 record
//!   (`responseHeadQueued`), never a flag the worker wrote: a request that
//!   ends without its response gets a 5xx before a head and RST_STREAM after
//!   one.
//! - Every finish but the teardown's queues the request's connection for a
//!   turn, so the connection's deadline follows the requests it still
//!   serves (`deadline_driver.zig`) whatever ended this one.

const std = @import("std");

const ipc = @import("collo_ipc");
const supervision = @import("collo_server_supervisor");
const pool_limits = @import("collo_limits").pool;
const access_log = @import("collo_server_analytics").access;
const worker_shared_page = @import("collo_worker_state").page;
const fault = @import("../fault.zig");
const server_responses = @import("../server_responses.zig");
const http2_writing = @import("../http2/writing.zig");
const admission = @import("admission.zig");
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const dispatch = @import("dispatch.zig");
const h2_worker_ipc = @import("h2_worker_ipc.zig");
const request_slot_mod = @import("request_slot.zig");
const worker_registration = @import("worker_registration.zig");

const pool = supervision.pool;
const WorkerPool = supervision.WorkerPool;
const SettleOutcome = supervision.SettleOutcome;
const WorkerRecord = supervision.worker_table.Record;
const ConnectionSlot = connection_slot.Slot;
const RequestSlot = request_slot_mod.RequestSlot;
const LaneFault = fault.LaneFault;
const CompletedStatus = worker_shared_page.CompletedStatus;

/// The status an access record reports for a request whose client went away
/// before it was answered, the one a worker reports for `client_closed`.
pub const client_closed_status: u16 = 499;

/// What ended a request.
pub const RequestOutcome = union(enum) {
    /// The worker published the request's completion, drained by this lane
    /// or forwarded by the worker's reader.
    worker_completion: worker_shared_page.WorkerCompletionRecord,
    /// The request waited for a worker slot past its deadline: 503.
    waiter_expired,
    /// No worker slot serves the waiting request: the pool's waiter FIFO is
    /// full, no worker is live and no launch is in flight, or the lane could
    /// not keep the request's head: 503.
    unserved,
    /// The lane answered the waiting request itself with this response,
    /// already written.
    rejected: server_responses.Id,
    /// The client reset the stream, or its connection closed, before the
    /// worker heard of the request.
    stream_gone,
    /// The request outlived its deadline on a worker that left service for
    /// it (`deadline_grace_expired`): 504, or RST_STREAM once its response
    /// head went out.
    deadline_expired,
    /// The request's deadline passed while its `request_begin` waited for
    /// room in its worker's control socket: 504. The worker never heard of
    /// the request, and a send that would block is backpressure, so the
    /// worker stays in service.
    send_expired,
    /// The request's worker died: 502, or RST_STREAM once its response head
    /// went out.
    worker_died: WorkerDeath,
    /// The lane is tearing down; its connections close without an answer.
    shutdown,
};

/// Why a request's worker died, as the request's records carry it.
pub const WorkerDeath = struct {
    /// The error code (`worker_fault.deathStatus`).
    status: CompletedStatus,
    reason: fault.WorkerFaultReason,
};

/// How a request that ends as an outcome is reported: the response the lane
/// writes when the stream is open and no response head went out (null for
/// none), the status and error code of its access record, and the worker
/// fault that ended it, which its access record and usage floor name.
pub const Ending = struct {
    response: ?server_responses.Id,
    status: u16,
    error_code: CompletedStatus,
    worker_fault: ?fault.WorkerFaultReason = null,
};

/// The report of a request that ends as `outcome`. Pure and file-level, so
/// the mapping is testable without a lane.
pub fn endingFor(outcome: RequestOutcome) Ending {
    return switch (outcome) {
        // The worker's own status is recorded whether or not its response
        // went out, including the 499 it reports for `client_closed`.
        .worker_completion => |completion| .{
            .response = null,
            .status = completion.http_status,
            .error_code = errorCodeFromDoneStatus(doneStatus(completion)),
        },
        // A request that reached no worker ends as `done` in the worker's
        // vocabulary, whatever the lane answered.
        .waiter_expired, .unserved => .{
            .response = .service_unavailable,
            .status = server_responses.get(.service_unavailable).status,
            .error_code = .done,
        },
        .rejected => |response_id| .{
            .response = null,
            .status = server_responses.get(response_id).status,
            .error_code = .done,
        },
        .stream_gone => .{ .response = null, .status = client_closed_status, .error_code = .client_closed },
        .deadline_expired => .{
            .response = .gateway_timeout,
            .status = server_responses.get(.gateway_timeout).status,
            .error_code = .deadline,
            .worker_fault = .deadline_grace_expired,
        },
        .send_expired => .{
            .response = .gateway_timeout,
            .status = server_responses.get(.gateway_timeout).status,
            .error_code = .deadline,
        },
        .worker_died => |death| .{
            .response = .bad_gateway,
            .status = server_responses.get(.bad_gateway).status,
            .error_code = death.status,
            .worker_fault = death.reason,
        },
        // Teardown is the server's restart; its record says 503, the
        // retryable class of a restarting service.
        .shutdown => .{
            .response = null,
            .status = server_responses.get(.service_unavailable).status,
            .error_code = .internal_error,
        },
    };
}

/// The access record's error code for a completion status. The switch has no
/// `else`, so a new `RequestDoneStatus` does not compile until it is given a
/// code here.
pub fn errorCodeFromDoneStatus(status: ipc.RequestDoneStatus) CompletedStatus {
    return switch (status) {
        .ok => .done,
        .bad_request => .bad_request,
        .js_exception => .js_exception,
        .internal_error => .internal_error,
        .deadline_timeout => .deadline,
        .worker_crash => .crash,
        .client_closed => .client_closed,
    };
}

/// The usage settle of a dispatched request that ended as `ended`: a
/// completion means the worker appended its own record first; a request the
/// server ended gets a floor with its error code and the worker fault that
/// ended it, unless its begin never reached the worker, which then never ran
/// it.
pub fn settleOutcomeFor(begin_sent: bool, ended: RequestOutcome) SettleOutcome {
    switch (ended) {
        .worker_completion => return .completed,
        else => {
            if (!begin_sent)
                return .abandoned;
            const ending = endingFor(ended);
            return .{ .floor = .{
                .status = ending.error_code,
                .worker_fault = workerFaultLabel(ending.worker_fault),
            } };
        },
    }
}

/// The label a record carries for `reason`, "" for none.
fn workerFaultLabel(reason: ?fault.WorkerFaultReason) []const u8 {
    const known = reason orelse return "";
    return known.label();
}

fn doneStatus(completion: worker_shared_page.WorkerCompletionRecord) ipc.RequestDoneStatus {
    return std.meta.intToEnum(ipc.RequestDoneStatus, completion.status) catch .worker_crash;
}

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const Connection = connection_flow.Methods(Self);
        const Dispatch = dispatch.Methods(Self);
        const WorkerIpc = h2_worker_ipc.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// Ends the request in `request_slot` for `outcome`: emits its access
        /// record, settles a dispatched request's usage and notes the end of
        /// the egress token it carried, answers or resets its stream as the
        /// outcome and the lane's own record of the stream say, frees the
        /// lane's slot and its wheel entry, and gives a worker slot back to
        /// the pool, which may hand it to a waiter at once. A waiting request
        /// leaves its pool's FIFO. An inactive slot is left alone.
        ///
        /// Every finish then queues the request's connection for a turn,
        /// whichever path it took and whatever ended it. The request no
        /// longer serves its stream, which can leave the connection with no
        /// request at all and so calls for its stall or idle deadline, and
        /// only a drive files that (`connection_flow.zig`). A finish runs
        /// from deadline expiries, commands and worker faults as well as
        /// from drives, and the answer it writes needs no poll, so nothing
        /// else would bring the connection back.
        pub fn finishRequest(self: *Self, request_slot: u32, outcome: RequestOutcome) LaneFault!void {
            if (request_slot >= self.requests.capacity())
                return error.RequestSlotOutOfRange;
            const slot = self.requests.get(request_slot) orelse return;
            const connection_key = slot.connection_key;
            if (slot.worker) |worker| {
                try finishDispatched(self, request_slot, worker, outcome);
            } else {
                try finishWaiting(self, request_slot, outcome);
            }
            // The lane's teardown closes every connection without a turn.
            if (outcome == .shutdown)
                return;
            switch (self.connections.lookup(connection_key.slot, connection_key.generation)) {
                .live => |runtime| Connection.keepConnectionAfterActiveRequest(self, runtime),
                .stale_generation, .vacant, .out_of_range => {},
            }
        }

        /// Ends the dispatched request in `request_slot` with the completion
        /// parked on it, and returns whether one was parked.
        pub fn finishParkedCompletion(self: *Self, request_slot: u32) LaneFault!bool {
            if (request_slot >= self.requests.capacity())
                return error.RequestSlotOutOfRange;
            const slot = self.requests.get(request_slot) orelse return false;
            if (!slot.dispatched())
                return false;
            const outcome: RequestOutcome = .{ .worker_completion = slot.pending_worker_completion orelse return false };
            try finishRequest(self, request_slot, outcome);
            return true;
        }

        fn finishWaiting(self: *Self, request_slot: u32, outcome: RequestOutcome) LaneFault!void {
            const slot = &self.requests.entries[request_slot];
            // False when a handoff already took the waiter: its
            // `dispatch_ready` finds the request gone and gives the slot back.
            _ = self.service.supervisor.poolFor(slot.route.definition).cancelWaiter(slot.request_key);
            const ending = endingFor(outcome);
            slot.access.error_code = ending.error_code;
            emitAccessRecord(self, slot, ending.status, .server);
            if (outcome != .shutdown) {
                if (Admission.requestConnection(self, slot)) |runtime| {
                    const stream_id = slot.ingress_channel_id;
                    if ((runtime.h2StreamState(stream_id) orelse .vacant) == .preparing) {
                        if (ending.response) |response_id|
                            try Admission.writeH2ServerResponse(self, runtime, stream_id, response_id);
                        Admission.finishH2LocalResponse(self, runtime, stream_id);
                    }
                }
            }
            freeRequestSlot(self, request_slot);
        }

        fn finishDispatched(
            self: *Self,
            request_slot: u32,
            worker: *WorkerRecord,
            outcome: RequestOutcome,
        ) LaneFault!void {
            const slot = &self.requests.entries[request_slot];
            var ended = outcome;
            if (slot.pending_worker_completion) |parked| {
                ended = .{ .worker_completion = parked };
                slot.pending_worker_completion = null;
            }

            const runtime: ?*ConnectionSlot = if (ended == .shutdown) null else Admission.requestConnection(self, slot);
            var ending = endingFor(ended);
            // A worker that completed without a response head on an open
            // stream gets its client a 502, and the record says so.
            const answer: ?server_responses.Id = switch (ended) {
                .worker_completion => if (runtime) |connection|
                    if (completionLeftNoAnswer(connection, slot)) .bad_gateway else null
                else
                    null,
                else => ending.response,
            };
            switch (ended) {
                .worker_completion => |completion| {
                    if (answer) |response_id|
                        ending.status = server_responses.get(response_id).status;
                    // Only the worker can measure these; the duration and the
                    // identity stay the lane's, so a worker cannot forge them.
                    slot.access.cpu_time_ns = completion.cpu_time_ns;
                    slot.access.io_time_ns = completion.io_time_ns;
                    slot.access.waiting_ns = completion.waiting_ns;
                },
                else => self.lane.counters.completed_requests += 1,
            }
            slot.access.error_code = ending.error_code;
            slot.access.worker_fault = workerFaultLabel(ending.worker_fault);
            emitAccessRecord(self, slot, ending.status, .worker);
            self.service.supervisor.settleRequest(worker, slot.request_id, settleOutcomeFor(slot.begin_sent, ended));
            if (slot.egress_gateway_session_id != 0) {
                self.egress_lease.noteEnded(slot.egress_gateway_generation, .{
                    .session_id = slot.egress_gateway_session_id,
                    .request_id = slot.request_id,
                    .request_generation = slot.request_key.generation,
                });
            }
            if (runtime) |connection| {
                if (answer) |response_id|
                    try WorkerIpc.answerUnfinishedStream(self, slot, response_id);
                try leaveStream(self, connection, slot);
            }

            const registration_index = WorkerRegistration.findCompletionRegistrationIndex(self, slot.worker_key) orelse
                return error.WorkerCompletionRegistrationNotFound;
            self.registrations.entries[registration_index].removeInflight(slot.request_key);
            const worker_slot = slot.worker_slot;
            freeRequestSlot(self, request_slot);
            try WorkerRegistration.releaseRegistrationIfIdle(self, registration_index);
            try releaseWorkerSlot(self, worker, worker_slot);
        }

        /// Takes a finished request off its stream. A response whose end
        /// never went out is reset, since nothing else ends the stream.
        fn leaveStream(
            self: *Self,
            runtime: *ConnectionSlot,
            slot: *const RequestSlot,
        ) LaneFault!void {
            // A write above may have closed the connection.
            if (!runtime.isLive())
                return;
            switch (runtime.h2RemoveRequest(self.service.allocator, slot.request_key)) {
                .none, .closed, .draining => {},
                .unfinished => try http2_writing.queueRstStream(Self, self, runtime, slot.ingress_channel_id, .internal_error),
            }
        }

        /// Gives `worker_slot` of `worker` back to its pool. A slot the pool
        /// hands on goes to its waiter: this lane's own waiting request is
        /// dispatched on it here, while the lane's loop runs, and another
        /// lane gets `dispatch_ready`. A handoff that cannot be used is
        /// released again, and one whose post the waiter's lane refuses goes
        /// back with the grant that lane never saw (`Pool.returnHandoff`), so
        /// the slot ends with a request, on the free list, or with the dead
        /// worker. `error.SlotNotHeld` from the pool is a lane fault: the
        /// lane's own record of the slot is broken.
        pub fn releaseWorkerSlot(self: *Self, worker: *WorkerRecord, worker_slot: pool.Slot) LaneFault!void {
            const worker_pool = self.service.supervisor.poolFor(worker.definition_index);
            const released = try worker_pool.release(worker, worker_slot, self.monotonicNowNs());
            try handOn(self, worker, worker_slot, released);
        }

        /// Gives back a slot of `worker` handed to this lane that it will not
        /// use, with the reader grant the handoff carried: a `dispatch_ready`
        /// still queued when the lane tears down
        /// (`command_flow.returnQueuedHandoffs`). The slot may go on to
        /// another lane's waiter as `releaseWorkerSlot` hands one on.
        pub fn returnHandoff(
            self: *Self,
            worker: *WorkerRecord,
            worker_slot: pool.Slot,
            reader: pool.ReaderGrant,
        ) LaneFault!void {
            const worker_pool = self.service.supervisor.poolFor(worker.definition_index);
            const released = try worker_pool.returnHandoff(worker, worker_slot, self.lane.lane_id, reader, self.monotonicNowNs());
            try handOn(self, worker, worker_slot, released);
        }

        /// Acts on what the pool did with a slot this lane gave back, and on
        /// each handoff that follows from it, until the slot rests.
        fn handOn(
            self: *Self,
            worker: *WorkerRecord,
            worker_slot: pool.Slot,
            first: WorkerPool.Released,
        ) LaneFault!void {
            const worker_pool = self.service.supervisor.poolFor(worker.definition_index);
            var released = first;
            var readmit: ?u32 = null;
            var handoffs: usize = 0;
            while (true) : (handoffs += 1) {
                // Each handoff takes a waiter off the pool's FIFO.
                std.debug.assert(handoffs <= pool_limits.pool_waiters_max);
                switch (released) {
                    .idle => break,
                    .retire => {
                        self.service.queueRetirement(worker);
                        break;
                    },
                    .handed_to => |handoff| {
                        // A lane past its loop, at teardown, has no ring to
                        // dispatch with; its own waiter goes the way a refused
                        // post does.
                        if (handoff.waiter.lane != self.lane.lane_id or self.runtime_ring == null) {
                            if (try self.postToLane(handoff.waiter.lane, .{ .dispatch_ready = .{
                                .request_key = handoff.waiter.request_key,
                                .worker_key = worker.key(),
                                .worker = worker,
                                .slot = worker_slot,
                                .reader = handoff.reader,
                            } }))
                                break;
                            // The waiter's lane is not running or its queue is
                            // full, so its request ends with it.
                            self.lane.counters.silent_queue_overflows += 1;
                            released = try worker_pool.returnHandoff(
                                worker,
                                worker_slot,
                                handoff.waiter.lane,
                                handoff.reader,
                                self.monotonicNowNs(),
                            );
                            continue;
                        }
                        try WorkerRegistration.dischargeReaderGrant(self, worker, handoff.reader);
                        if (Admission.waitingRequestSlot(self, handoff.waiter.request_key)) |request_slot| {
                            switch (try Dispatch.useHandoff(self, request_slot, worker, worker_slot)) {
                                .dispatched => break,
                                .unused => {},
                                .worker_dead => readmit = request_slot,
                            }
                        }
                        released = try worker_pool.release(worker, worker_slot, self.monotonicNowNs());
                    },
                }
            }
            if (readmit) |request_slot|
                try Admission.placeWaitingRequest(self, request_slot);
        }

        /// Pushes the request's one access record onto this lane's ring and
        /// clears the slot's facts, so no path emits twice. Facts never
        /// stamped (`request_id` 0) emit nothing. The worker identity is the
        /// slot's own, the worker this lane dispatched the request to.
        fn emitAccessRecord(
            self: *Self,
            slot: *RequestSlot,
            http_status: u16,
            answered_by: access_log.AnsweredBy,
        ) void {
            if (slot.access.request_id == 0)
                return;
            slot.access.worker_id = slot.worker_key.worker_id;
            slot.access.worker_generation = slot.worker_key.worker_generation;
            _ = self.access_ring.push(access_log.recordFromFacts(
                slot.access,
                http_status,
                answered_by,
                self.monotonicNowNs(),
            ));
            slot.access.request_id = 0;
        }

        /// Frees what the slot owns, its wheel entry and its slab entry. A
        /// cancelled wheel entry can leave the timerfd armed early, which
        /// costs one spurious wake that re-arms it.
        fn freeRequestSlot(self: *Self, request_slot: u32) void {
            const slot = &self.requests.entries[request_slot];
            if (slot.head) |*owned|
                owned.deinit();
            slot.head = null;
            if (slot.parked_begin) |*parked|
                parked.deinit();
            slot.parked_begin = null;
            _ = self.lane.cancelRequestDeadline(&slot.deadline);
            self.requests.release(request_slot);
            // A finish that finds nothing counted means a request finished
            // that was never counted. The guard stays because underflowing
            // the count would be worse than the divergence, and the counter
            // makes the divergence observable. No assertion of the same
            // predicate precedes it: in ReleaseFast an assertion is a promise
            // to the optimizer, which could then delete the else arm and the
            // counter with it.
            if (self.request_count != 0) {
                self.request_count -= 1;
            } else {
                self.request_underflow += 1;
            }
        }
    };
}

/// Whether a worker's completion leaves its client without an answer: the
/// stream is still the request's and open, and no response head of the
/// worker went out on it.
fn completionLeftNoAnswer(runtime: *const ConnectionSlot, slot: *const RequestSlot) bool {
    if (slot.h2_client_reset)
        return false;
    switch (runtime.h2StreamState(slot.ingress_channel_id) orelse .vacant) {
        .preparing, .active => {},
        .vacant, .draining_response => return false,
    }
    return !runtime.responseHeadQueued(slot.ingress_channel_id);
}
