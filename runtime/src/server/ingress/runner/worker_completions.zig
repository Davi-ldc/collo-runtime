//! The completion ring of a worker an ingress lane reads, on that lane's
//! thread, and the completions other lanes' readers forward to it. The
//! reader drains the ring only after the worker's control socket is empty,
//! so a request's descriptors precede its completion in its owner's queue. A
//! completion for a request of this lane is delivered here; one for another
//! lane's request is forwarded to that lane (`forwarded_completion`), which
//! delivers it the same way (`applyForwardedCompletion`).
//!
//! - A completion is worker output. The drain hands on the copy it loaded
//!   once and validated (`WorkerWriterView.drainWorkerCompletions`), and
//!   everything here acts on that copy. It reaches a request only when its
//!   worker identity is the reader's registration's and it names, by key and
//!   request id, a request this lane sent to that worker; anything else is
//!   counted as stale. The reader forwards a completion of another lane's
//!   request once, and only while the worker's request table holds the
//!   request under that key (`RequestTable.claimCompletion`), so a worker
//!   cannot fill another lane's queue with completions. A completion naming
//!   a lane the server does not have, or a request id the table holds under
//!   another key, is a worker fault.
//! - A completion finishes its request at once, unless the lane's own record
//!   says the response head went out and the response has not ended: then
//!   it parks on the request until the end arrives, the stream goes away, or
//!   the request's wheel entry fires, which stays armed.
//! - The ring's consumer is the worker's one reader, so no other lane moves
//!   its tail, which lives in the record's view of the page
//!   (`HostCursors.completion_tail`) and passes from reader to reader with
//!   the role, under the pool's mutex. The reader reads the ring through that
//!   view, which lasts while the record serves the worker: the reader role
//!   keeps the worker in its pool's table, and the reaper unmaps the page
//!   only after the worker left it.

const worker_shared_page = @import("collo_worker_state").page;
const fault = @import("../fault.zig");
const ingress_state = @import("../state.zig");
const lane_commands = @import("../lane_commands.zig");
const admission = @import("admission.zig");
const h2_worker_ipc = @import("h2_worker_ipc.zig");
const request_finish = @import("request_finish.zig");
const worker_control = @import("worker_control.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");

const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;
const WorkerCompletionRecord = worker_shared_page.WorkerCompletionRecord;

/// Rounds of `drainWorkerControl` a completion wake runs before the ring. A
/// worker sends a request's response before it publishes the request's
/// completion, so the ring is drained only once the control socket is empty,
/// and a socket still holding packets after this many rounds leaves the ring
/// for the next pass.
const control_rounds_before_ring_max: usize = 4;

/// What the grace backstop's read of a worker found (`readForBackstop`).
pub const BackstopRead = enum {
    /// The control socket emptied and the ring was drained, or a fault in
    /// the output ran the death path.
    done,
    /// The worker kept its control socket filling for the whole bounded
    /// read, so its ring, where a completion would sit behind that output,
    /// was left unread.
    socket_busy,
};

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);
        const WorkerFault = worker_fault.Methods(Self);
        const WorkerIpc = h2_worker_ipc.Methods(Self);
        const WorkerControl = worker_control.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// Loop handler: the completion eventfd of a worker this lane reads
        /// fired. Reads the control socket to its end, then the ring, and
        /// runs the death path on a fault in either; otherwise re-arms the
        /// reader's polls. When the socket is not empty after
        /// `control_rounds_before_ring_max` rounds the eventfd stays unread,
        /// so its re-armed poll fires again on the next pass.
        pub fn handleWorkerCompletions(self: *Self, registration_index: u32) LaneFault!void {
            if (registration_index >= self.completion_registration_count)
                return error.InvalidCompletionRegistration;
            const registration = &self.completion_registrations[registration_index];
            if (!registration.inUse() or !registration.reading())
                return error.InvalidCompletionRegistration;
            var rounds: usize = 0;
            const control_empty = while (rounds < control_rounds_before_ring_max) : (rounds += 1) {
                switch (try WorkerControl.drainWorkerControl(self, registration_index, .yield_to_backlog)) {
                    .ok => {},
                    .would_block => break true,
                    .fault => |reason| return WorkerFault.faultWorker(self, registration_index, reason),
                }
            } else false;
            if (control_empty) {
                switch (try drainCompletions(self, registration_index)) {
                    .ok, .would_block => {},
                    .fault => |reason| return WorkerFault.faultWorker(self, registration_index, reason),
                }
            }
            _ = try WorkerRegistration.armWorkerPolls(self, registration_index);
        }

        /// The grace backstop's read of a worker this lane reads, so that a
        /// completion the worker published in time wins over the fault: the
        /// control socket to its end, reading through any connection's
        /// backlog (`worker_fault.drainControlToEnd`), then the ring, and the
        /// reader's polls armed again. A fault in that output runs the death
        /// path here.
        pub fn readForBackstop(self: *Self, registration_index: u32) LaneFault!BackstopRead {
            if (registration_index >= self.completion_registration_count)
                return error.InvalidCompletionRegistration;
            switch (try WorkerFault.drainControlToEnd(self, registration_index)) {
                .would_block => {},
                .ok => {
                    _ = try WorkerRegistration.armWorkerPolls(self, registration_index);
                    return .socket_busy;
                },
                .fault => |reason| {
                    try WorkerFault.faultWorker(self, registration_index, reason);
                    return .done;
                },
            }
            switch (try drainCompletions(self, registration_index)) {
                .ok, .would_block => {},
                .fault => |reason| {
                    try WorkerFault.faultWorker(self, registration_index, reason);
                    return .done;
                },
            }
            _ = try WorkerRegistration.armWorkerPolls(self, registration_index);
            return .done;
        }

        /// Drains the completion eventfd, then the completion ring, of the
        /// worker this lane reads through registration `registration_index`;
        /// the caller drained the worker's control socket first. One drain
        /// takes every record the worker published by then. Returns `.fault`
        /// for a ring the worker marked fatal or corrupted, a record that
        /// fails its checks, or a completion naming a lane that does not
        /// exist; the records after a faulty one are not delivered.
        pub fn drainCompletions(self: *Self, registration_index: u32) LaneFault!WorkerOutcome {
            const registration = &self.completion_registrations[registration_index];
            const worker = registration.worker orelse return error.InvalidCompletionRegistration;
            const view = if (worker.handle.metrics) |*metrics| metrics else return error.InvalidCompletionRegistration;
            // The eventfd goes first: a record published after the ring's
            // drain comes with a write of its own, so its poll fires again.
            const wakes = worker_shared_page.drainCompletionEventfd(registration.event_fd) catch |err|
                switch (try fault.classifyWorkerError(.{ .wake = err })) {
                    .ok, .would_block => 0,
                    .fault => |reason| return .{ .fault = reason },
                };
            if (wakes != 0)
                self.lane.counters.worker_completion_eventfd_wakes += 1;
            var records: [worker_shared_page.COMPLETION_RING_COUNT]WorkerCompletionRecord = undefined;
            const count = view.drainWorkerCompletions(&records) catch |err| {
                self.lane.counters.worker_completion_drain_fatal_errors += 1;
                return fault.classifyWorkerError(.{ .completion = err });
            };
            for (records[0..count]) |*record| {
                switch (try routeCompletion(self, registration_index, record)) {
                    .ok, .would_block => {},
                    .fault => |reason| return .{ .fault = reason },
                }
            }
            return .ok;
        }

        /// Applies a completion the worker's reader forwarded
        /// (`forwarded_completion`) as one this lane drained itself. A
        /// request that ended since, or keys naming another request or
        /// worker, drop it.
        pub fn applyForwardedCompletion(self: *Self, forwarded: lane_commands.ForwardedCompletion) LaneFault!void {
            const request_slot = completedRequestSlot(
                self,
                forwarded.request_key,
                forwarded.worker_key,
                forwarded.record.external_request_id,
            ) orelse {
                self.lane.counters.stale_worker_completion += 1;
                return;
            };
            try deliverCompletion(self, request_slot, forwarded.record);
        }

        /// Sends one drained record where it belongs: to this lane's request,
        /// to the lane that owns the request, or nowhere when it is stale.
        fn routeCompletion(
            self: *Self,
            registration_index: u32,
            record: *const WorkerCompletionRecord,
        ) LaneFault!WorkerOutcome {
            const registration = &self.completion_registrations[registration_index];
            const worker_key = registration.worker_key;
            if (record.worker_id != worker_key.worker_id or
                record.worker_generation != worker_key.worker_generation)
            {
                self.lane.counters.stale_worker_completion += 1;
                return .ok;
            }
            const request_key: ingress_state.RequestKey = .{
                .lane_id = record.request_lane_id,
                .slot = record.request_slot,
                .generation = record.request_generation,
            };
            if (request_key.lane_id != self.lane.lane_id) {
                // The server never sends a request from a lane it does not
                // have.
                if (request_key.lane_id >= self.service.lanes.len)
                    return .{ .fault = .completion_record_invalid };
                const worker = registration.worker orelse return error.InvalidCompletionRegistration;
                switch (worker.requests.claimCompletion(record.external_request_id, request_key)) {
                    .claimed => {},
                    .stale => {
                        self.lane.counters.stale_worker_completion += 1;
                        return .ok;
                    },
                    .mismatch => return .{ .fault = .completion_record_invalid },
                }
                // The worker is done with the request, so nothing more of a
                // response the reader stopped forwarding can follow.
                registration.forward_loss.remove(request_key);
                // The completion may take the owner's command reserve, so
                // only a lane that is not running refuses it.
                if (!try self.postToLane(request_key.lane_id, .{ .forwarded_completion = .{
                    .request_key = request_key,
                    .worker_key = worker_key,
                    .record = record.*,
                } }))
                    self.lane.counters.silent_queue_overflows += 1;
                return .ok;
            }
            const request_slot = completedRequestSlot(self, request_key, worker_key, record.external_request_id) orelse {
                self.lane.counters.stale_worker_completion += 1;
                return .ok;
            };
            try deliverCompletion(self, request_slot, record.*);
            return .ok;
        }

        /// The slot of the request a completion names, when it is this lane's
        /// request, sent to `worker_key` under `request_id`.
        fn completedRequestSlot(
            self: *Self,
            request_key: ingress_state.RequestKey,
            worker_key: ingress_state.WorkerKey,
            request_id: u64,
        ) ?u32 {
            const request_slot = Admission.findRequestSlot(self, request_key) orelse return null;
            const slot = &self.dynamic_requests[request_slot];
            if (!slot.dispatched())
                return null;
            if (!slot.worker_key.eql(worker_key))
                return null;
            if (slot.request_id != request_id)
                return null;
            // A worker learns of a request only from its begin.
            if (!slot.begin_sent)
                return null;
            return request_slot;
        }

        /// Parks `completion` on its request, behind a response head the lane
        /// queued whose end has not, or finishes the request with it.
        fn deliverCompletion(self: *Self, request_slot: u32, completion: WorkerCompletionRecord) LaneFault!void {
            const slot = &self.dynamic_requests[request_slot];
            switch (WorkerIpc.h2CompletionDeferDecision(self, slot)) {
                // A request completes once; a second completion for it
                // changes nothing.
                .already_pending => {
                    self.lane.counters.stale_worker_completion += 1;
                    return;
                },
                .should_store => {
                    self.lane.recordCompletionDrained(1);
                    WorkerIpc.storeDeferredWorkerCompletionForH2Descriptors(self, slot, completion);
                    return;
                },
                .no => {},
            }
            self.lane.recordCompletionDrained(1);
            try RequestFinish.finishRequest(self, request_slot, .{ .worker_completion = completion });
        }
    };
}
