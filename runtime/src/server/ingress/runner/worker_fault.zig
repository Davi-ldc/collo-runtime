//! The death of a worker an ingress lane reads or holds a slot of, on the
//! lane thread: the death path a fault starts, the last read of a dead
//! worker's output, the `worker_died` notices to the other lanes and the end
//! of this lane's requests on the worker.
//!
//! Invariants:
//! - A death runs on the lane that sees it, outside any stream handler: a
//!   fault met inside one takes the worker out of service at once and waits
//!   on the lane's death queue for the rest of its path (`deferWorkerFault`,
//!   `processDeferredWorkerFaults`). The worker leaves service first
//!   (`Pool.markDead` in `server/supervisor/pool.zig`).
//! - When this lane reads the worker and the reason leaves its output trusted
//!   (`finalDrainTrusted`), the last of that output is read and forwarded
//!   before the other lanes hear of the death, so what was forwarded to them
//!   precedes the notice in their queues.
//! - Each request of this lane on the dead worker ends with 502, with 504
//!   when the grace backstop found it past its deadline, or with RST_STREAM
//!   once its response head went out.
//! - Every retirement is the reaper's (`queueRetirement`). No kill, exit
//!   wait, usage drain or cgroup removal runs on the lane.

const supervision = @import("collo_server_supervisor");
const worker_shared_page = @import("collo_worker_state").page;
const fault = @import("../fault.zig");
const completions = @import("../completions.zig");
const ingress_state = @import("../state.zig");
const admission = @import("admission.zig");
const request_finish = @import("request_finish.zig");
const work_queues = @import("work_queues.zig");
const worker_completions = @import("worker_completions.zig");
const worker_control = @import("worker_control.zig");
const worker_registration = @import("worker_registration.zig");

const WorkerPool = supervision.WorkerPool;
const WorkerRecord = supervision.worker_table.Record;
const LaneFault = fault.LaneFault;
const CompletedStatus = worker_shared_page.CompletedStatus;
const RequestOutcome = request_finish.RequestOutcome;

/// Rounds of `drainWorkerControl` the last read of a dead worker's control
/// socket runs before it gives up on a worker that keeps writing. A dead
/// worker's socket holds at most its receive buffer, which this many rounds
/// read whole.
const final_drain_rounds_max: usize = 64;

/// The error code of the requests a worker fault ends, when the worker's own
/// end does not say more (`deathStatus`). Failures on the server's side of
/// the channel record `internal_error`, so they do not count against the
/// tenant's error rate.
pub fn errorCodeForFault(reason: fault.WorkerFaultReason) CompletedStatus {
    return switch (reason) {
        .allocation_failed, .egress_session_failed => .internal_error,
        .deadline_grace_expired => .deadline,
        .packet_short,
        .packet_too_large,
        .unknown_kind,
        .unexpected_descriptor,
        .too_many_descriptors,
        .zero_length_datagram_with_descriptors,
        .ingress_channel_undecodable,
        .fs_fault_request_undecodable,
        .descriptor_names_no_request,
        .response_head_invalid,
        .response_descriptor_invalid,
        .completion_ring_fatal,
        .completion_ring_corrupt,
        .completion_sequence_mismatch,
        .completion_record_invalid,
        .payload_ring_invalid,
        .channel_failed,
        .peer_closed,
        .exited,
        .usage_record_protocol,
        .log_ring_corrupt,
        => .crash,
    };
}

/// Whether what a worker wrote before a fault for `reason` is worth reading:
/// a worker that hung up, exited, overran a deadline or lost its egress
/// session wrote honest output, while one that broke the protocol did not,
/// and a failed channel or allocation would fail the read again.
pub fn finalDrainTrusted(reason: fault.WorkerFaultReason) bool {
    return switch (reason) {
        .peer_closed, .exited, .deadline_grace_expired, .egress_session_failed => true,
        .packet_short,
        .packet_too_large,
        .unknown_kind,
        .unexpected_descriptor,
        .too_many_descriptors,
        .zero_length_datagram_with_descriptors,
        .ingress_channel_undecodable,
        .fs_fault_request_undecodable,
        .descriptor_names_no_request,
        .response_head_invalid,
        .response_descriptor_invalid,
        .completion_ring_fatal,
        .completion_ring_corrupt,
        .completion_sequence_mismatch,
        .completion_record_invalid,
        .payload_ring_invalid,
        .allocation_failed,
        .channel_failed,
        .usage_record_protocol,
        .log_ring_corrupt,
        => false,
    };
}

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const Completions = worker_completions.Methods(Self);
        const Queues = work_queues.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);
        const WorkerControl = worker_control.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// The death path of the worker of registration `registration_index`
        /// for `reason`, which this lane saw: a fault in its output or its
        /// sends, its pidfd, the grace backstop, or a `worker_died` from the
        /// lane or thread that saw it first. Takes the worker out of service,
        /// reads and forwards the last of its output when this lane reads it
        /// and the reason leaves that output trusted, tells the other lanes,
        /// ends this lane's requests on it, gives the reader role back, and
        /// asks for a replacement. The first reason this lane recorded for
        /// the worker is the one its records carry, and a second call finds
        /// the worker out of service already and only ends what this lane
        /// still has on it.
        pub fn faultWorker(self: *Self, registration_index: u32, reason: fault.WorkerFaultReason) LaneFault!void {
            const registration = try WorkerRegistration.registrationAt(self, registration_index);
            const worker = registration.worker.?;
            if (registration.fault == null)
                registration.fault = reason;
            const recorded = registration.fault.?;
            const definition = worker.definition_index;
            // A deferred fault took the worker out of service already and
            // kept the notice for this path (`deferWorkerFault`).
            const death = registration.death_notice orelse
                self.service.supervisor.poolFor(definition).markDead(worker, registration.worker_key);
            registration.death_notice = null;
            if (registration.reading() and finalDrainTrusted(recorded))
                try drainDeadWorker(self, registration_index);
            if (death) |notice|
                try announceDeath(self, worker, recorded, notice);
            try finishRequestsOnWorker(self, registration_index, worker, recorded);
            try WorkerRegistration.endReading(self, registration_index, worker);
            try WorkerRegistration.releaseRegistrationIfIdle(self, registration_index);
            if (death != null)
                try Admission.growOrStrand(self, definition, .replacement);
        }

        /// The death path of `worker` for a fault this lane found in output
        /// another lane read for it, when this lane neither reads the worker
        /// nor holds a request on it: takes the worker out of service, tells
        /// the lanes the pool names, which end their requests on it, and asks
        /// for a replacement. Nothing of this lane keeps the worker in its
        /// pool, so the pool checks under its lock that the record still
        /// holds `worker_key` (`Pool.markDead`).
        pub fn faultWorkerSeenElsewhere(
            self: *Self,
            worker: *WorkerRecord,
            worker_key: ingress_state.WorkerKey,
            reason: fault.WorkerFaultReason,
        ) LaneFault!void {
            const definition = worker.definition_index;
            // Null: another caller took the worker out of service, whose path
            // finishes it, or the record holds a later worker.
            const notice = self.service.supervisor.poolFor(definition).markDead(worker, worker_key) orelse {
                self.lane.counters.stale_commands += 1;
                return;
            };
            try announceDeath(self, worker, reason, notice);
            try Admission.growOrStrand(self, definition, .replacement);
        }

        /// Records a fault of the worker of registration `registration_index`
        /// for `processDeferredWorkerFaults`, and takes the worker out of
        /// service at once, so no lane takes a slot of it in the rest of the
        /// pass. The rest of the death path waits for the stream handler
        /// running now to return, because it drives other connections and
        /// reads the worker's output, which must not happen in the middle of
        /// a connection's frames. The registration keeps the reason and the
        /// pool's death notice until that path runs, even if its last request
        /// ends first (`worker_registration.releaseRegistrationIfIdle`).
        pub fn deferWorkerFault(self: *Self, registration_index: u32, reason: fault.WorkerFaultReason) LaneFault!void {
            const registration = try WorkerRegistration.registrationAt(self, registration_index);
            const worker = registration.worker.?;
            if (registration.fault == null)
                registration.fault = reason;
            if (registration.death_notice == null)
                registration.death_notice = self.service.supervisor.poolFor(worker.definition_index).markDead(worker, registration.worker_key);
            try Queues.enqueueDeath(self, registration_index);
        }

        /// Runs the worker faults deferred since the last pass, one per
        /// registration, and returns whether it ran any. The event loop calls
        /// it on every pass.
        pub fn processDeferredWorkerFaults(self: *Self) LaneFault!bool {
            var did_work = false;
            var popped: usize = 0;
            while (popped < self.completion_registrations.len) : (popped += 1) {
                const registration_index = Queues.popDeath(self) orelse break;
                // A registration with a deferred fault stays bound to its
                // worker until this runs
                // (`worker_registration.releaseRegistrationIfIdle`).
                const registration = try WorkerRegistration.registrationAt(self, registration_index);
                const reason = registration.fault orelse return error.InvalidCompletionRegistration;
                try faultWorker(self, registration_index, reason);
                did_work = true;
            }
            return did_work;
        }

        /// Reads the control socket of the worker of registration
        /// `registration_index` until it is empty, through any connection's
        /// backlog, for at most `final_drain_rounds_max` rounds: the reads
        /// that must see everything the worker wrote, the last read of a dead
        /// worker and the grace backstop. Returns `.would_block` once the
        /// socket is empty, `.ok` when the worker kept it filling for all
        /// those rounds, and `.fault` for a fault in the output.
        pub fn drainControlToEnd(self: *Self, registration_index: u32) LaneFault!fault.WorkerOutcome {
            var rounds: usize = 0;
            while (rounds < final_drain_rounds_max) : (rounds += 1) {
                const outcome = try WorkerControl.drainWorkerControl(self, registration_index, .read_through);
                switch (outcome) {
                    .ok => {},
                    .would_block, .fault => return outcome,
                }
            }
            return .ok;
        }

        /// The last read of a dead worker this lane reads: its control socket
        /// to the end, then its completion ring, forwarding what belongs to
        /// other lanes. A fault in that output ends the read, and the rest is
        /// left unread.
        fn drainDeadWorker(self: *Self, registration_index: u32) LaneFault!void {
            switch (try drainControlToEnd(self, registration_index)) {
                .would_block => {},
                .ok => return,
                // A hang-up ends a dead worker's output, which stays trusted,
                // and leaves its socket empty.
                .fault => |cause| switch (cause) {
                    .peer_closed => {},
                    else => return,
                },
            }
            _ = try Completions.drainCompletions(self, registration_index);
        }

        /// Posts `worker_died` to every other lane `notice` names, and queues
        /// the retirement of a worker no lane holds or reads.
        pub fn announceDeath(
            self: *Self,
            worker: *WorkerRecord,
            reason: fault.WorkerFaultReason,
            notice: WorkerPool.Death,
        ) LaneFault!void {
            for (notice.slice()) |lane| {
                if (lane == self.lane.lane_id)
                    continue;
                // A `worker_died` may take the queue's reserve
                // (`commands.zig`), so a refusal means that lane is not
                // running.
                if (!try self.postToLane(lane, .{ .worker_died = .{
                    .worker_key = worker.key(),
                    .reason = reason,
                } }))
                    self.lane.counters.silent_queue_overflows += 1;
            }
            if (notice.retire)
                self.service.queueRetirement(worker);
        }

        /// Ends each request of this lane on the worker of registration
        /// `registration_index`, which is dead for `reason`. A request the
        /// grace backstop found past its deadline answers 504, every other
        /// one 502.
        fn finishRequestsOnWorker(
            self: *Self,
            registration_index: u32,
            worker: *WorkerRecord,
            reason: fault.WorkerFaultReason,
        ) LaneFault!void {
            const registration = &self.completion_registrations[registration_index];
            const worker_key = registration.worker_key;
            var request_keys: [completions.max_worker_inflight_requests]ingress_state.RequestKey = undefined;
            const request_count = registration.copyInflight(&request_keys);
            if (request_count == 0)
                return;
            const status = deathStatus(self, worker, reason);
            const now = self.monotonicNowNs();
            for (request_keys[0..request_count]) |request_key| {
                const request_slot = Admission.findRequestSlot(self, request_key) orelse continue;
                const slot = &self.dynamic_requests[request_slot];
                if (!slot.dispatched() or !slot.worker_key.eql(worker_key))
                    continue;
                const outcome: RequestOutcome = if (reason == .deadline_grace_expired and now >= slot.deadline_ns)
                    .deadline_expired
                else
                    .{ .worker_died = .{ .status = status, .reason = reason } };
                try RequestFinish.finishRequest(self, request_slot, outcome);
            }
        }

        /// The status the requests of a dead worker carry. A worker that
        /// hung up or exited may have been ended for memory, by its sentinel
        /// or the kernel, which only its page and cgroup can tell
        /// (`Supervisor.classifyWorkerDeath`, one cgroup read).
        fn deathStatus(self: *Self, worker: *WorkerRecord, reason: fault.WorkerFaultReason) CompletedStatus {
            return switch (reason) {
                .exited, .peer_closed => self.service.supervisor.classifyWorkerDeath(worker),
                else => errorCodeForFault(reason),
            };
        }
    };
}
