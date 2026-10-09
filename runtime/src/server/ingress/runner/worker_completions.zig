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
//!   the request's wheel entry fires, which stays armed. It is counted once,
//!   when it arrives.
//! - The completion eventfd also carries the worker's room in its
//!   server-to-worker payload ring: the worker writes it when it frees ring
//!   bytes a lane marked itself waiting for. After each drain of the eventfd
//!   the reader raises the `payload_credit` wake of every lane registered in
//!   the worker's record (`Record.body_waiters`, `request_body.zig`), this
//!   one included. While the worker's forwarding window is full
//!   (`Registration.window_blocked`), a wake does only that, and the control
//!   socket and the ring wait for the window to reopen
//!   (`resumeWindowBlockedReaders`).
//! - The ring's consumer is the worker's one reader, so no other lane moves
//!   its tail, which lives in the record's view of the page
//!   (`HostCursors.completion_tail`) and passes from reader to reader with
//!   the role, under the pool's mutex. The reader reads the ring through that
//!   view, which lasts while the record serves the worker: the reader role
//!   keeps the worker in its pool's table, and the reaper unmaps the page
//!   only after the worker left it.

const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const worker_shared_page = @import("collo_worker_state").page;
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const lane_commands = @import("../lane_commands.zig");
const admission = @import("admission.zig");
const h2_worker_ipc = @import("h2_worker_ipc.zig");
const request_finish = @import("request_finish.zig");
const worker_control = @import("worker_control.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");
const runner = @import("root.zig");

const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;
const WorkerCompletionRecord = worker_shared_page.WorkerCompletionRecord;
const WorkerRecord = supervision.worker_table.Record;

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
        /// fired. Reads the control socket to its end, then the eventfd and
        /// the ring, and runs the death path on a fault in either; otherwise
        /// re-arms the reader's polls. When the socket is not empty after
        /// `control_rounds_before_ring_max` rounds, or the forwarding window
        /// filled, the eventfd stays unread, so its re-armed poll fires again
        /// on the next pass. While the window is full, the wake only drains
        /// the eventfd and wakes the request bodies waiting for ring room.
        pub fn handleWorkerCompletions(self: *Self, registration_index: u32) LaneFault!void {
            const registration = try readingRegistration(self, registration_index);
            if (registration.window_blocked) {
                switch (try drainWake(self, registration)) {
                    .ok, .would_block => {},
                    .fault => |reason| return WorkerFault.faultWorker(self, registration_index, reason),
                }
                return WorkerRegistration.armWorkerPolls(self, registration_index);
            }
            var rounds: usize = 0;
            const control_empty = while (rounds < control_rounds_before_ring_max) : (rounds += 1) {
                switch (try WorkerControl.drainWorkerControl(self, registration_index, .yield_to_backlog)) {
                    .ok => if (registration.window_blocked) break false,
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
            try WorkerRegistration.armWorkerPolls(self, registration_index);
        }

        /// Handles this lane's `window_reopened` wake: every registration
        /// whose worker's forwarding window was full and has room again reads
        /// the worker's control socket and ring as a completion wake does.
        /// One whose window is still full stays blocked, with its mark as the
        /// window's waiter set again (`h2_worker_ipc.windowHasRoom`).
        pub fn resumeWindowBlockedReaders(self: *Self) LaneFault!void {
            for (self.registrations.touched(), 0..) |*registration, index| {
                if (!registration.inUse() or !registration.reading() or !registration.window_blocked)
                    continue;
                const worker = registration.worker orelse return error.InvalidCompletionRegistration;
                if (!h2_worker_ipc.windowHasRoom(worker, self.lane.lane_id))
                    continue;
                registration.window_blocked = false;
                try handleWorkerCompletions(self, @intCast(index));
            }
        }

        /// The grace backstop's read of a worker this lane reads, so that a
        /// completion the worker published in time wins over the fault: the
        /// control socket to its end, reading through any connection's
        /// backlog and the forwarding window (`worker_fault.drainControlToEnd`),
        /// then the ring, and the reader's polls armed again. A fault in that
        /// output runs the death path here.
        pub fn readForBackstop(self: *Self, registration_index: u32) LaneFault!BackstopRead {
            _ = try readingRegistration(self, registration_index);
            switch (try WorkerFault.drainControlToEnd(self, registration_index)) {
                .would_block => {},
                .ok => {
                    try WorkerRegistration.armWorkerPolls(self, registration_index);
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
            try WorkerRegistration.armWorkerPolls(self, registration_index);
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
            const registration = &self.registrations.entries[registration_index];
            const worker = registration.worker orelse return error.InvalidCompletionRegistration;
            const view = if (worker.handle.metrics) |*metrics| metrics else return error.InvalidCompletionRegistration;
            switch (try drainWake(self, registration)) {
                .ok, .would_block => {},
                .fault => |reason| return .{ .fault = reason },
            }
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

        /// Drains the completion eventfd of the worker `registration` reads,
        /// then raises the `payload_credit` wake of each lane registered as
        /// waiting for room in the worker's server-to-worker ring. The
        /// eventfd goes first: a record or a release the worker publishes
        /// after the drain writes the eventfd again, so its poll fires again,
        /// and a lane registers before it marks the ring, so the release that
        /// answers its mark finds its registration here.
        fn drainWake(self: *Self, registration: *completions.Registration) LaneFault!WorkerOutcome {
            const wakes = worker_shared_page.drainCompletionEventfd(registration.event_fd) catch |err|
                switch (try fault.classifyWorkerError(.{ .wake = err })) {
                    .ok, .would_block => 0,
                    .fault => |reason| return .{ .fault = reason },
                };
            if (wakes != 0)
                self.lane.counters.worker_completion_eventfd_wakes += 1;
            const worker = registration.worker orelse return error.InvalidCompletionRegistration;
            for (&worker.body_waiters) |*waiter| {
                // Only a lane writes a waiter, and a registration the release
                // answered happened before the eventfd write this drain took,
                // so a plain load sees it.
                if (waiter.load(.monotonic) == 0)
                    continue;
                const lane = waiter.swap(0, .seq_cst);
                if (lane == 0)
                    continue;
                try self.service.raiseLaneWake(lane - 1, runner.wake.payload_credit);
            }
            return .ok;
        }

        /// Sends one drained record where it belongs: to this lane's request,
        /// to the lane that owns the request, or nowhere when it is stale.
        fn routeCompletion(
            self: *Self,
            registration_index: u32,
            record: *const WorkerCompletionRecord,
        ) LaneFault!WorkerOutcome {
            const registration = &self.registrations.entries[registration_index];
            const worker_key = registration.worker_key;
            if (record.worker_id != worker_key.worker_id or
                record.worker_generation != worker_key.worker_generation)
            {
                self.lane.counters.stale_worker_completion += 1;
                return .ok;
            }
            const request_key: lifecycle.RequestKey = .{
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
                // The completion takes any free place of the owner's queue,
                // a reserved one first (`commands.zig`), so only a lane that
                // is not running or whose queue is full refuses it.
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
            request_key: lifecycle.RequestKey,
            worker_key: lifecycle.WorkerKey,
            request_id: u64,
        ) ?u32 {
            const request_slot = Admission.findRequestSlot(self, request_key) orelse return null;
            const slot = &self.requests.entries[request_slot];
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
            const slot = &self.requests.entries[request_slot];
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

        /// The registration at `registration_index`, which must read its
        /// worker: only the reader's polls reach these handlers.
        fn readingRegistration(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            const registration = self.registrations.get(registration_index) orelse
                return error.InvalidCompletionRegistration;
            if (!registration.reading())
                return error.InvalidCompletionRegistration;
            return registration;
        }
    };
}
