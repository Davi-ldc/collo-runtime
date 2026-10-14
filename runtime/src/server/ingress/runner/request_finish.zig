//! The end of an ingress lane's requests and the worker slots they give back,
//! on the lane thread: the one finish of every request whatever ended it,
//! with its access record and the answer or reset its stream gets, and the
//! handoff of a freed worker slot to the next waiter.
//!
//! Invariants:
//! - A request finishes once and emits one access record. The lane writes
//!   the record's identity, times and every status it synthesizes, and the
//!   status of the worker's response head it queued, which is what the
//!   client received (`AccessFacts.response_status`); a worker's
//!   `request_done` supplies its error code and its measures, and its status
//!   only when no head of the worker went out, and neither status nor error
//!   code once the lane answered the client itself
//!   (`RequestSlot.local_answer`).
//! - A dispatched request's record carries its usage (`access.Usage` in
//!   `server/analytics/access.zig`): the measures of its `request_done`,
//!   origin `worker`; for a request the server ended after its begin reached
//!   the worker, the CPU the worker's page holds for it
//!   (`Record.usageFloor` in `server/supervisor/worker_table.zig`), origin
//!   `server`; and no measures for one whose begin never reached the worker.
//!   Its wall time runs from the dispatch the lane stamped
//!   (`AccessFacts.dispatched_mono_ns`) to the instant the record's duration
//!   ends at. The floor is read while the request still holds its worker
//!   slot, which keeps the worker's page mapped, and a worker cannot choose
//!   whose record its measures enter: the lane names the request and the
//!   socket names the worker.
//! - A dispatched request leaves its worker's request table
//!   (`RequestTable.end`, or `remove` when its begin never reached the
//!   worker, in `server/supervisor/request_table.zig`) before its worker
//!   slot goes back, so a worker never has more entries than slots.
//! - A request whose begin reached the worker finishes only at its
//!   `request_done`, at its worker's death or at the lane's teardown, so its
//!   pool slot comes back only once the worker holds the request no more,
//!   and a worker never holds more requests than its `concurrency`. The lane
//!   still answers the client at once whatever the worker does: a client's
//!   reset and a body the lane refuses leave the request to its
//!   `request_done` after a `request_reset` (`dispatch.cancelRequestToWorker`),
//!   and the worker answers 504 itself at the deadline, which the grace
//!   backstop enforces with the worker's death (`deadline_driver.zig`).
//! - A freed slot goes to the oldest waiter at once (`Pool.release` in
//!   `server/supervisor/pool.zig`): this lane's own waiter is dispatched on
//!   it here, another lane's gets `dispatch_ready`, and a worker the pool
//!   retires goes to the reaper (`queueRetirement`).
//! - Whether a response head went out is the lane's own HTTP/2 record
//!   (`responseHeadQueued`), never a flag the worker wrote: a request that
//!   ends without its response gets a 5xx before a head and RST_STREAM after
//!   one, and a `request_done` ahead of its response's end resets the
//!   stream at once (`leaveStream`), since nothing of the worker follows it.
//! - Every finish but the teardown's queues the request's connection for a
//!   turn, so the connection's deadline follows the requests it still
//!   serves (`deadline_driver.zig`) whatever ended this one.

const std = @import("std");

const ipc = @import("collo_ipc");
const supervision = @import("collo_server_supervisor");
const pool_limits = @import("collo_limits").pool;
const access_log = @import("collo_server_analytics").access;
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
const WorkerRecord = supervision.worker_table.Record;
const ConnectionSlot = connection_slot.Slot;
const RequestSlot = request_slot_mod.RequestSlot;
const LaneFault = fault.LaneFault;
const ErrorCode = access_log.ErrorCode;
const RequestDone = ipc.ingress_channel.RequestDone;

/// The status an access record reports for a request whose client went away
/// before it was answered, the one a worker reports for `client_closed`.
pub const client_closed_status: u16 = 499;

/// What ended a request.
pub const RequestOutcome = union(enum) {
    /// The worker's `request_done`, read by this lane or forwarded by the
    /// worker's reader (`request_done.zig`).
    worker_done: RequestDone,
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
    /// The request outlived its deadline on a worker that left service for a
    /// deadline, the one this fault reason names: a request's past the grace
    /// backstop (`deadline_grace_expired`), or its VM thread's owner's
    /// (`owner_overran`). 504, or RST_STREAM once its response head went out.
    deadline_expired: fault.WorkerFaultReason,
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

/// Why a request's worker died, as the request's access record carries it.
pub const WorkerDeath = struct {
    /// The error code (`worker_fault.deathStatus`).
    status: ErrorCode,
    reason: fault.WorkerFaultReason,
};

/// How a request that ends as an outcome is reported: the response the lane
/// writes when the stream is open and no response head went out (null for
/// none), the status and error code of its access record, and the worker
/// fault that ended it, which its access record names.
pub const Ending = struct {
    response: ?server_responses.Id,
    status: u16,
    error_code: ErrorCode,
    worker_fault: ?fault.WorkerFaultReason = null,
};

/// The report of a request that ends as `outcome`. Pure and file-level, so
/// the mapping is testable without a lane.
pub fn endingFor(outcome: RequestOutcome) Ending {
    return switch (outcome) {
        // The worker's own status, the 499 it reports for `client_closed`
        // included; the finish replaces it with the status of the head the
        // lane queued, when one went out (`workerDoneStatus`).
        .worker_done => |done| .{
            .response = null,
            .status = doneHttpStatus(done),
            .error_code = errorCodeFromDoneStatus(done.status),
        },
        // A request that reached no worker ends as `done` in the worker's
        // vocabulary, whatever the lane answered.
        .waiter_expired, .unserved => .{
            .response = .service_unavailable,
            .status = server_responses.get(.service_unavailable).status,
            .error_code = .done,
        },
        // The lane refuses a request for its body alone, which the client
        // sent wrong.
        .rejected => |response_id| .{
            .response = null,
            .status = server_responses.get(response_id).status,
            .error_code = .bad_request,
        },
        .stream_gone => .{ .response = null, .status = client_closed_status, .error_code = .client_closed },
        .deadline_expired => |reason| .{
            .response = .gateway_timeout,
            .status = server_responses.get(.gateway_timeout).status,
            .error_code = .deadline,
            .worker_fault = reason,
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

/// The status a `request_done` reports, which the access record of its
/// request carries when no response head of the worker went out
/// (`workerDoneStatus`): the worker's own, or, when the worker answered with
/// no status (`http_status` 0), the 499 of a client that went away for
/// `client_closed` and otherwise the 502 the lane answers a stream the
/// worker left without a head (`requestDoneLeftNoAnswer`).
pub fn doneHttpStatus(done: RequestDone) u16 {
    if (done.http_status != 0)
        return done.http_status;
    return switch (done.status) {
        .client_closed => client_closed_status,
        else => server_responses.get(.bad_gateway).status,
    };
}

/// The usage the access record of a request its `request_done` ended
/// carries: the worker's measures, its claim about its own request, which
/// no other request's record reads. Pure and file-level, so the copy is
/// testable without a lane.
pub fn usageOfDone(done: RequestDone) access_log.Usage {
    return .{
        .origin = .worker,
        .exec_ns = done.exec_ns,
        .waiting_ns = done.waiting_ns,
        .io_ns = done.io_ns,
        .cpu_ns = done.cpu_ns,
        .client_served_bytes = done.client_served_bytes,
        .fetch_sent_bytes = done.fetch_sent_bytes,
        .fetch_received_bytes = done.fetch_received_bytes,
    };
}

/// The access record's error code for a `request_done` status. The switch
/// has no `else`, so a new `RequestDoneStatus` does not compile until it is
/// given a code here.
pub fn errorCodeFromDoneStatus(status: ipc.RequestDoneStatus) ErrorCode {
    return switch (status) {
        .ok => .done,
        .bad_request => .bad_request,
        .js_exception => .js_exception,
        .internal_error => .internal_error,
        .deadline_timeout => .deadline,
        .worker_crash => .crash,
        .client_closed => .client_closed,
        .cpu_exceeded => .cpu,
        .worker_retiring => .worker_retiring,
        .worker_stopped => .worker_stopped,
    };
}

/// Whether `outcome` may end a request its worker holds, one whose begin
/// reached the worker: its `request_done`, its worker's death, or the lane's
/// teardown.
fn endsRequestTheWorkerHolds(outcome: RequestOutcome) bool {
    return switch (outcome) {
        .worker_done, .deadline_expired, .worker_died, .shutdown => true,
        .waiter_expired, .unserved, .rejected, .stream_gone, .send_expired => false,
    };
}

/// The label a record carries for `reason`, "" for none.
fn workerFaultLabel(reason: ?fault.WorkerFaultReason) []const u8 {
    const known = reason orelse return "";
    return known.label();
}

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const Connection = connection_flow.Methods(Self);
        const Dispatch = dispatch.Methods(Self);
        const WorkerIpc = h2_worker_ipc.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// Ends the request in `request_slot` for `outcome`: emits its access
        /// record, with a dispatched request's usage, takes a dispatched
        /// request out of its worker's request table and notes the end of
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

        fn finishWaiting(self: *Self, request_slot: u32, outcome: RequestOutcome) LaneFault!void {
            const slot = &self.requests.entries[request_slot];
            // False when a handoff already took the waiter: its
            // `dispatch_ready` finds the request gone and gives the slot back.
            _ = self.service.supervisor.poolFor(slot.route.definition).cancelWaiter(slot.request_key);
            const ending = endingFor(outcome);
            slot.access.error_code = ending.error_code;
            emitAccessRecord(self, slot, ending.status, .server, self.monotonicNowNs(), null);
            if (outcome != .shutdown) {
                if (Admission.requestConnection(self, slot)) |runtime| {
                    const stream_id = slot.ingress_channel_id;
                    if ((runtime.h2StreamState(stream_id) orelse .vacant) == .preparing) {
                        if (ending.response) |response_id|
                            _ = try Admission.writeH2ServerResponse(self, runtime, stream_id, response_id);
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
            // Every other outcome is only ever given to a request whose begin
            // never left (the header).
            if (slot.begin_sent) std.debug.assert(endsRequestTheWorkerHolds(outcome));
            const runtime: ?*ConnectionSlot = if (outcome == .shutdown) null else Admission.requestConnection(self, slot);
            var ending = endingFor(outcome);
            // A worker that ended its request without a response head on an
            // open stream gets its client a 502, and the record says so.
            const answer: ?server_responses.Id = switch (outcome) {
                .worker_done => if (runtime) |connection|
                    if (requestDoneLeftNoAnswer(connection, slot)) .bad_gateway else null
                else
                    null,
                else => ending.response,
            };
            if (outcome == .worker_done)
                ending.status = workerDoneStatus(slot, ending.status, answer);
            self.lane.counters.completed_requests += 1;
            var answered_by: access_log.AnsweredBy = .worker;
            if (slot.local_answer) |local| {
                // The client got the lane's refusal of its body, and nothing
                // the worker or its end wrote after it.
                ending.status = server_responses.get(local).status;
                ending.error_code = endingFor(.{ .rejected = local }).error_code;
                answered_by = .server;
            }
            slot.access.error_code = ending.error_code;
            slot.access.worker_fault = workerFaultLabel(ending.worker_fault);
            const usage = usageOf(slot, worker, outcome, ending.error_code);
            emitAccessRecord(self, slot, ending.status, answered_by, self.monotonicNowNs(), usage);
            // Only a request the worker heard of can name itself in the
            // worker's console lines, so only its entry is remembered.
            if (slot.begin_sent) {
                worker.requests.end(slot.request_id);
            } else {
                worker.requests.remove(slot.request_id);
            }
            if (runtime) |connection| {
                if (answer) |response_id|
                    try WorkerIpc.answerUnfinishedStream(self, slot, response_id);
                try leaveStream(self, connection, slot);
            }

            const registration_index = WorkerRegistration.findRegistrationIndex(self, slot.worker_key) orelse
                return error.WorkerRegistrationNotFound;
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
        /// (`command_flow.returnQueuedHandoffs`), or one whose worker left
        /// service while it travelled (`command_flow.handleDispatchReady`).
        /// The slot may go on to
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
                    // The last slot of a worker retiring on its notice, which
                    // a lane still reads: that reader gives its role up
                    // through its queue, after whatever drain runs now,
                    // this lane's own included. A refused post leaves the
                    // release to the reaper's retry.
                    .release_reader => |tenure| {
                        if (!try self.postToLane(tenure.lane, .{ .release_worker = .{
                            .worker_key = worker.key(),
                            .epoch = tenure.epoch,
                        } }))
                            self.lane.counters.release_worker_refusals += 1;
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

        /// Pushes the request's one access record, ended at `finished_ns` on
        /// the lane's clock and carrying `usage` for a dispatched request,
        /// onto this lane's ring and clears the slot's facts, so no path
        /// emits twice. Facts never stamped (`request_id` 0) emit nothing.
        /// The worker identity is the slot's own, the worker this lane
        /// dispatched the request to.
        fn emitAccessRecord(
            self: *Self,
            slot: *RequestSlot,
            http_status: u16,
            answered_by: access_log.AnsweredBy,
            finished_ns: u64,
            usage: ?access_log.Usage,
        ) void {
            if (slot.access.request_id == 0)
                return;
            slot.access.worker_id = slot.worker_key.worker_id;
            slot.access.worker_generation = slot.worker_key.worker_generation;
            var record = access_log.recordFromFacts(slot.access, http_status, answered_by, finished_ns);
            record.usage = usage;
            _ = self.access_ring.push(record);
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

/// The usage of a dispatched request that ended as `ended` with
/// `error_code` (the file header's rule): its `request_done`'s, the
/// worker's own count of a request the server ended after its begin reached
/// the worker, read from the worker's page while the request still holds
/// its worker slot (`Record.usageFloor` in
/// `server/supervisor/worker_table.zig`), or no measures for a request the
/// worker never heard of, which ran none of it.
fn usageOf(
    slot: *const RequestSlot,
    worker: *WorkerRecord,
    ended: RequestOutcome,
    error_code: ErrorCode,
) access_log.Usage {
    switch (ended) {
        .worker_done => |done| return usageOfDone(done),
        else => {},
    }
    if (!slot.begin_sent)
        return .{ .origin = .server };
    return worker.usageFloor(slot.worker_slot, .{
        .request_id = slot.request_id,
        .request_generation = slot.request_key.generation,
    }, error_code);
}

/// The status the access record of a request its `request_done` ended
/// carries: the lane's answer when the worker left the stream without one
/// (`answer`), else the status of the response head the lane queued for the
/// worker, which is what the client received, and only when no head went
/// out the worker's own report (`reported`, `doneHttpStatus`), its claim
/// about a response nobody saw.
fn workerDoneStatus(slot: *const RequestSlot, reported: u16, answer: ?server_responses.Id) u16 {
    if (answer) |response_id|
        return server_responses.get(response_id).status;
    if (slot.access.response_status != 0)
        return slot.access.response_status;
    return reported;
}

/// Whether a worker's `request_done` leaves its client without an answer:
/// the stream is still the request's and open, and no response head of the
/// worker went out on it.
fn requestDoneLeftNoAnswer(runtime: *const ConnectionSlot, slot: *const RequestSlot) bool {
    if (slot.h2_client_reset)
        return false;
    switch (runtime.h2StreamState(slot.ingress_channel_id) orelse .vacant) {
        .preparing, .active => {},
        .vacant, .draining_response => return false,
    }
    return !runtime.responseHeadQueued(slot.ingress_channel_id);
}
