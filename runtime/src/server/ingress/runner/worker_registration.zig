//! An ingress lane's registration of each worker it sends to or reads
//! (`completions.Registration`), on the lane thread: binding a registration
//! to its worker and freeing it, the polls it arms on the worker's
//! descriptors, and this lane's reader tenure over the worker, from the grant
//! that starts it to the transfer that ends it.
//!
//! Invariants:
//! - A registration exists while this lane reads its worker (`tenure`), has
//!   a request on it, or has a fault of it deferred.
//! - The reader role moves only at an idle moment, on the reader's own
//!   thread. The reader gives it up through `Pool.transferReader` in
//!   `server/supervisor/pool.zig`, which keeps a live worker's role while the
//!   worker has requests in flight or the reader still holds ring payloads,
//!   and a lane that takes a slot of a worker another lane reads only asks
//!   that reader to give the role up (`release_worker`). A dead worker's role
//!   goes back on its death path.
//! - A reader polls the worker's completion eventfd, fault socket and pidfd
//!   for the whole tenure, and its control socket while the worker's
//!   forwarding window has room (`window_blocked`), reading the completion
//!   ring through the record's mapping of the worker's page. Any
//!   registration polls the control socket's writability while one of its
//!   requests' sends waits for room there. A send that waits for room in the
//!   worker's payload ring polls nothing: the reader wakes it
//!   (`request_body.zig`). The launcher set the server's ends of the worker's
//!   sockets non-blocking once, so no dispatch changes a descriptor's flags.
//! - Every poll carries the registration's epoch, which is new each time
//!   the registration is bound, stops reading or is freed (`newEpoch`), so
//!   the completion of an earlier poll is ignored.

const std = @import("std");

const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const fault = @import("../fault.zig");
const completions = @import("../completions.zig");
const admission = @import("admission.zig");
const command_flow = @import("command_flow.zig");
const event_sources = @import("event_sources.zig");
const request_slot_mod = @import("request_slot.zig");
const ring_driver = @import("ring_driver.zig");
const worker_fault = @import("worker_fault.zig");

const pool = supervision.pool;
const WorkerRecord = supervision.worker_table.Record;
const RequestSlot = request_slot_mod.RequestSlot;
const LaneFault = fault.LaneFault;
const LaneRing = event_sources.LaneRing;

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const Command = command_flow.Methods(Self);
        const RingDriver = ring_driver.Methods(Self);
        const WorkerFault = worker_fault.Methods(Self);

        /// Discharges what taking a slot of `worker` owes its reader role
        /// (`pool.ReaderGrant`): this lane becomes the reader for the whole
        /// tenure, or asks the reader lane to give the role up. That lane
        /// keeps reading and forwarding until it does, so a lost request
        /// costs only the forwarding, and the pool asks again on the next
        /// grant (`Pool.releaseRequestLost`).
        pub fn dischargeReaderGrant(self: *Self, worker: *WorkerRecord, grant: pool.ReaderGrant) LaneFault!void {
            switch (grant) {
                .already => {},
                .you_become_reader => |epoch| {
                    const registration_index = try registrationFor(self, worker);
                    const registration = &self.registrations.entries[registration_index];
                    // The pool grants a tenure only to a lane that does not
                    // read the worker, and a tenure ends in this lane's own
                    // registration.
                    if (registration.reading())
                        return error.InvalidCompletionRegistration;
                    registration.tenure = .{ .lane = self.lane.lane_id, .epoch = epoch };
                    try armWorkerPolls(self, registration_index);
                },
                .transfer_from => |tenure| {
                    if (!try self.postToLane(tenure.lane, .{ .release_worker = .{
                        .worker_key = worker.key(),
                        .epoch = tenure.epoch,
                    } })) {
                        self.lane.counters.release_worker_refusals += 1;
                        self.service.supervisor.poolFor(worker.definition_index).releaseRequestLost(worker, tenure);
                    }
                },
            }
        }

        /// Acts on how `Pool.transferReader` left this lane's reader tenure
        /// of the worker of registration `registration_index`: stops reading
        /// unless the role was kept, wakes the reaper to watch a worker left
        /// without a reader, and queues a finished worker's retirement.
        pub fn applyReaderTransfer(self: *Self, registration_index: u32, transfer: pool.Transfer) LaneFault!void {
            const registration = try registrationAt(self, registration_index);
            const worker = registration.worker.?;
            switch (transfer) {
                // The role is unchanged. `giveUpTenure` frees the payloads a
                // `.free_held_payloads` names and asks again before it acts.
                .kept, .free_held_payloads => return,
                // The pool names no such tenure, so nothing is read on its
                // behalf any more.
                .stale => try stopReading(self, registration_index),
                .vacated => {
                    try stopReading(self, registration_index);
                    self.service.reaper.wakeForPidfdScan();
                },
                .retire => {
                    try stopReading(self, registration_index);
                    self.service.queueRetirement(worker);
                },
            }
            try releaseRegistrationIfIdle(self, registration_index);
        }

        /// The index of this lane's registration of `worker`, binding a free
        /// one when there is none. The registration borrows the descriptors
        /// of the worker's handle: the record outlives every registration of
        /// it, since the pool keeps the worker until no lane holds or reads
        /// it, and keeps a dead worker until its retirement, which a lane
        /// holding an unannounced death notice has not queued yet.
        pub fn registrationFor(self: *Self, worker: *WorkerRecord) LaneFault!u32 {
            const worker_key = worker.key();
            for (self.registrations.touched(), 0..) |*registration, index| {
                if (registration.inUse() and registration.worker == worker and registration.worker_key.eql(worker_key))
                    return @intCast(index);
            }
            const acquired = self.registrations.acquire() orelse return error.TooManyWorkerCompletionRegistrations;
            // A registration is freed only with no death queued for it
            // (`releaseRegistrationIfIdle`), so its place carries none.
            std.debug.assert(!acquired.entry.slab_link.queued);
            const registration = acquired.entry;
            registration.worker = worker;
            registration.worker_key = worker_key;
            registration.generation = newEpoch(self);
            registration.event_fd = worker.handle.completion_eventfd;
            registration.control_fd = worker.handle.control_fd;
            registration.pidfd = worker.handle.pidfd;
            registration.fs_fault_fd = worker.handle.fs_fault_fd;
            registration.ingress_payload = &worker.handle.ingress_payload;
            registration.ingress_payload_credit_eventfd = worker.handle.ingress_payload_credit_eventfd;
            self.lane.counters.worker_completion_registrations += 1;
            return acquired.index;
        }

        pub fn findCompletionRegistrationIndex(self: *Self, worker_key: lifecycle.WorkerKey) ?u32 {
            for (self.registrations.touched(), 0..) |*registration, index| {
                if (registration.inUse() and registration.worker_key.eql(worker_key))
                    return @intCast(index);
            }
            return null;
        }

        /// Adds a request this lane dispatched to the worker of registration
        /// `registration_index`.
        pub fn attachRequest(
            self: *Self,
            registration_index: u32,
            request_key: lifecycle.RequestKey,
        ) LaneFault!void {
            const registration = try registrationAt(self, registration_index);
            if (registration.containsInflight(request_key))
                return;
            // A worker has at most `concurrency` slots, within the list's
            // bound, so a full list means the lane's records disagree.
            if (registration.inflight_request_len == registration.inflight_request_keys.len)
                return error.WorkerInflightRequestListFull;
            registration.inflight_request_keys[registration.inflight_request_len] = request_key;
            registration.inflight_request_len += 1;
        }

        /// Arms every poll registration `registration_index` should have and
        /// has not: a reader's polls on the worker's completion eventfd,
        /// fault socket and pidfd, and on its control socket unless the
        /// forwarding window is full, and the writability poll while one of
        /// this lane's requests waits on the worker's full control socket.
        /// Every poll is one-shot; its completion clears its flag, and this
        /// arms it again. Arming only prepares the submission, which the
        /// pass's one `io_uring_enter` hands over.
        pub fn armWorkerPolls(self: *Self, registration_index: u32) LaneFault!void {
            const registration = try registrationAt(self, registration_index);
            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            if (registration.reading()) {
                try armReadPoll(ring, registration, registration_index, .worker_completion, registration.event_fd, &registration.poll_registered);
                if (!registration.window_blocked)
                    try armReadPoll(ring, registration, registration_index, .worker_control, registration.control_fd, &registration.control_poll_registered);
                try armReadPoll(ring, registration, registration_index, .worker_fs_fault, registration.fs_fault_fd, &registration.fs_fault_poll_registered);
                try armReadPoll(ring, registration, registration_index, .worker_pidfd, registration.pidfd, &registration.pidfd_poll_registered);
            }
            for (registration.inflight_request_keys[0..registration.inflight_request_len]) |request_key| {
                const request_slot = Admission.findRequestSlot(self, request_key) orelse continue;
                if (self.requests.entries[request_slot].send_blocked == .socket) {
                    try RingDriver.armWorkerControlWritable(self, registration_index);
                    return;
                }
            }
        }

        /// `armWorkerPolls` for the registration of the worker of the
        /// dispatched request in `slot`.
        pub fn armWorkerPollsFor(self: *Self, slot: *const RequestSlot) LaneFault!void {
            const registration_index = findCompletionRegistrationIndex(self, slot.worker_key) orelse
                return error.WorkerCompletionRegistrationNotFound;
            try armWorkerPolls(self, registration_index);
        }

        fn armReadPoll(
            ring: *LaneRing,
            registration: *const completions.Registration,
            registration_index: u32,
            kind: event_sources.EventKind,
            fd: std.posix.fd_t,
            registered: *bool,
        ) LaneFault!void {
            if (registered.*)
                return;
            try ring.queuePoll(fd, event_sources.pollMask(event_sources.read_events), .{
                .kind = kind,
                .index = registration_index,
                .generation = registration.generation,
            });
            registered.* = true;
        }

        /// Prepares the cancel of a registration's poll of `kind` that is in
        /// flight. Without a ring, at teardown, the poll went with it.
        fn cancelPoll(
            self: *Self,
            registration: *const completions.Registration,
            registration_index: u32,
            kind: event_sources.EventKind,
            in_flight: *bool,
        ) LaneFault!void {
            if (!in_flight.*)
                return;
            in_flight.* = false;
            const ring = self.runtime_ring orelse return;
            try ring.queuePollCancel(
                .{ .kind = .worker_poll_cancel, .index = registration_index, .generation = registration.generation },
                .{ .kind = kind, .index = registration_index, .generation = registration.generation },
            );
        }

        /// Cancels every poll of registration `registration_index` still in
        /// flight and gives it a new epoch, so a completion that was already
        /// on its way reads as stale.
        fn cancelPolls(self: *Self, registration_index: u32) LaneFault!void {
            const registration = &self.registrations.entries[registration_index];
            try cancelPoll(self, registration, registration_index, .worker_completion, &registration.poll_registered);
            try cancelPoll(self, registration, registration_index, .worker_control, &registration.control_poll_registered);
            try cancelPoll(self, registration, registration_index, .worker_fs_fault, &registration.fs_fault_poll_registered);
            try cancelPoll(self, registration, registration_index, .worker_pidfd, &registration.pidfd_poll_registered);
            try cancelPoll(self, registration, registration_index, .worker_control_writable, &registration.control_writable_poll_registered);
            registration.generation = newEpoch(self);
        }

        /// The registration at `registration_index`, which must hold a
        /// worker: a caller reaches one only through a completion or a call
        /// that checked it, so anything else is the lane's own mistake.
        pub fn registrationAt(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            return self.registrations.get(registration_index) orelse error.InvalidCompletionRegistration;
        }

        /// Stops reading the worker of registration `registration_index`:
        /// cancels its polls, ends the tenure with the ring account and the
        /// forwarding losses it kept, and re-arms what the registration still
        /// needs for this lane's own requests.
        fn stopReading(self: *Self, registration_index: u32) LaneFault!void {
            const registration = &self.registrations.entries[registration_index];
            if (!registration.reading())
                return;
            try cancelPolls(self, registration_index);
            registration.endTenure();
            if (registration.inflight_request_len != 0)
                try armWorkerPolls(self, registration_index);
        }

        /// Frees a registration that neither reads its worker nor holds a
        /// request on it, cancelling the polls it still has in flight. One
        /// whose worker fault waits on the lane's death queue stays, with the
        /// reason and the death notice that path needs, until the path runs
        /// (`worker_fault.processDeferredWorkerFaults`).
        pub fn releaseRegistrationIfIdle(self: *Self, registration_index: u32) LaneFault!void {
            const registration = self.registrations.get(registration_index) orelse return;
            if (registration.reading() or registration.inflight_request_len != 0)
                return;
            if (registration.slab_link.queued)
                return;
            try cancelPolls(self, registration_index);
            self.registrations.release(registration_index);
        }

        /// Gives this lane's reader role over a dead `worker` back to its
        /// pool. A role granted to this lane with no tenure registered here
        /// is named only in the pool, and only this lane can end it.
        pub fn endReading(self: *Self, registration_index: u32, worker: *WorkerRecord) LaneFault!void {
            const registration = &self.registrations.entries[registration_index];
            if (registration.inUse() and registration.worker == worker and registration.reading()) {
                _ = try Command.giveUpTenure(self, registration_index);
                return;
            }
            const worker_pool = self.service.supervisor.poolFor(worker.definition_index);
            const view = worker_pool.inspect(worker) orelse return;
            const reader = view.reader orelse return;
            if (reader.lane != self.lane.lane_id)
                return;
            switch (worker_pool.transferReader(worker, reader, .nothing)) {
                .stale, .kept, .free_held_payloads => {},
                .vacated => self.service.reaper.wakeForPidfdScan(),
                .retire => self.service.queueRetirement(worker),
            }
        }

        /// Ends what this lane's registration `registration_index` still owes
        /// the other lanes and the pool when the lane tears down, after its
        /// requests ended and with its ring gone: the death a deferred fault
        /// took out of service and never announced, and the reader role,
        /// which a lane that stops can no longer serve. A busy worker's role
        /// stays named until its death or its last request's backstop
        /// (`Pool.transferReader` answers `.kept`).
        pub fn endRegistrationAtTeardown(self: *Self, registration_index: u32) LaneFault!void {
            const registration = &self.registrations.entries[registration_index];
            const worker = registration.worker orelse return;
            if (registration.death_notice) |notice| {
                registration.death_notice = null;
                // A deferred fault records its reason with the notice.
                const reason = registration.fault orelse return error.InvalidCompletionRegistration;
                try WorkerFault.announceDeath(self, worker, reason, notice);
            }
            if (registration.reading())
                _ = try Command.giveUpTenure(self, registration_index);
        }

        /// The lane's next poll epoch, never 0, which no poll was armed
        /// under before it wraps.
        fn newEpoch(self: *Self) u32 {
            self.registration_epoch +%= 1;
            if (self.registration_epoch == 0)
                self.registration_epoch = 1;
            return self.registration_epoch;
        }
    };
}
