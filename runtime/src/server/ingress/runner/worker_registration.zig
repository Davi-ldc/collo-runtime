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
//! - A reader polls the worker's completion eventfd, control socket, fault
//!   socket and pidfd for the whole tenure, reading the completion ring
//!   through the record's mapping of the worker's page. Any registration
//!   polls the payload credit eventfd or the control socket's writability
//!   while one of its requests' sends waits on them. The launcher set the
//!   server's ends of the worker's sockets non-blocking once, so no dispatch
//!   changes a descriptor's flags.
//! - A registration's generation advances when it stops reading and when it
//!   is freed, so the completion of an earlier poll is ignored.

const std = @import("std");

const supervision = @import("collo_server_supervisor");
const fault = @import("../fault.zig");
const completions = @import("../completions.zig");
const ingress_state = @import("../state.zig");
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
                    const registration = &self.completion_registrations[registration_index];
                    // The pool grants a tenure only to a lane that does not
                    // read the worker, and a tenure ends in this lane's own
                    // registration.
                    if (registration.reading())
                        return error.InvalidCompletionRegistration;
                    registration.tenure = .{ .lane = self.lane.lane_id, .epoch = epoch };
                    _ = try armWorkerPolls(self, registration_index);
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
            var vacant: ?u32 = null;
            for (self.completion_registrations[0..self.completion_registration_count], 0..) |*registration, index| {
                if (registration.inUse()) {
                    if (registration.worker == worker and registration.worker_key.eql(worker_key))
                        return @intCast(index);
                } else if (vacant == null) {
                    vacant = @intCast(index);
                }
            }
            const registration_index: u32 = vacant orelse grow: {
                if (self.completion_registration_count == self.completion_registrations.len)
                    return error.TooManyWorkerCompletionRegistrations;
                self.completion_registrations[self.completion_registration_count] = .{};
                self.completion_registration_count += 1;
                break :grow @intCast(self.completion_registration_count - 1);
            };
            const registration = &self.completion_registrations[registration_index];
            // A registration is freed only with no death queued for it
            // (`releaseRegistrationIfIdle`), so a free one carries none.
            std.debug.assert(!registration.death_queued);
            const generation = nextGeneration(registration.generation);
            registration.* = .{
                .worker = worker,
                .worker_key = worker_key,
                .generation = generation,
                .event_fd = worker.handle.completion_eventfd,
                .control_fd = worker.handle.control_fd,
                .pidfd = worker.handle.pidfd,
                .fs_fault_fd = worker.handle.fs_fault_fd,
                .ingress_payload = &worker.handle.ingress_payload,
                .ingress_payload_credit_eventfd = worker.handle.ingress_payload_credit_eventfd,
            };
            self.lane.counters.worker_completion_registrations += 1;
            return registration_index;
        }

        pub fn findCompletionRegistrationIndex(
            self: *Self,
            worker_key: ingress_state.WorkerKey,
        ) ?u32 {
            for (self.completion_registrations[0..self.completion_registration_count], 0..) |*registration, index| {
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
            request_key: ingress_state.RequestKey,
        ) LaneFault!void {
            const registration = &self.completion_registrations[registration_index];
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
        /// control socket, fault socket and pidfd, the payload credit poll
        /// while one of this lane's requests waits on the worker's full ring,
        /// and the writability poll while one waits on its full control
        /// socket. Every poll is one-shot; its completion clears its flag,
        /// and this arms it again. Returns whether this call armed the credit
        /// poll, which `EventSet.queuePoll` submits before it returns: the
        /// lanes with sends parked on one worker share its credit eventfd, so
        /// a credit written after a send's failed try and before this arm can
        /// be read by another lane first, and the caller tries its
        /// ring-blocked sends once more.
        pub fn armWorkerPolls(self: *Self, registration_index: u32) LaneFault!bool {
            const registration = try registrationAt(self, registration_index);
            const ring = self.runtime_ring orelse return error.IngressRingUnavailable;
            if (registration.reading()) {
                try armReadPoll(self, ring, registration_index, .worker_completion, registration.event_fd, &registration.poll_registered);
                try armReadPoll(self, ring, registration_index, .worker_control, registration.control_fd, &registration.control_poll_registered);
                try armReadPoll(self, ring, registration_index, .worker_fs_fault, registration.fs_fault_fd, &registration.fs_fault_poll_registered);
                try armReadPoll(self, ring, registration_index, .worker_pidfd, registration.pidfd, &registration.pidfd_poll_registered);
            }
            var waits_on_ring = false;
            var waits_on_socket = false;
            for (registration.inflight_request_keys[0..registration.inflight_request_len]) |request_key| {
                const request_slot = Admission.findRequestSlot(self, request_key) orelse continue;
                switch (self.dynamic_requests[request_slot].send_blocked) {
                    .none, .failed => {},
                    .ring => waits_on_ring = true,
                    .socket => waits_on_socket = true,
                }
            }
            var credit_armed = false;
            if (waits_on_ring and !registration.ingress_payload_credit_poll_registered) {
                try armReadPoll(self, ring, registration_index, .worker_payload_credit, registration.ingress_payload_credit_eventfd, &registration.ingress_payload_credit_poll_registered);
                credit_armed = true;
            }
            if (waits_on_socket)
                try RingDriver.armWorkerControlWritable(self, registration_index);
            return credit_armed;
        }

        /// `armWorkerPolls` for the registration of the worker of the
        /// dispatched request in `slot`.
        pub fn armWorkerPollsFor(self: *Self, slot: *const RequestSlot) LaneFault!bool {
            const registration_index = findCompletionRegistrationIndex(self, slot.worker_key) orelse
                return error.WorkerCompletionRegistrationNotFound;
            return armWorkerPolls(self, registration_index);
        }

        fn armReadPoll(
            self: *Self,
            ring: *std.os.linux.IoUring,
            registration_index: u32,
            kind: event_sources.EventKind,
            fd: std.posix.fd_t,
            registered: *bool,
        ) LaneFault!void {
            if (registered.*)
                return;
            try self.runtime_events.queuePoll(ring, fd, event_sources.pollMask(event_sources.read_events), .{
                .kind = kind,
                .index = registration_index,
                .generation = self.completion_registrations[registration_index].generation,
            });
            registered.* = true;
        }

        /// Submits the cancel of a registration's poll of `kind` that is in
        /// flight. Without a ring, at teardown, the poll went with it.
        fn cancelPoll(
            self: *Self,
            registration_index: u32,
            kind: event_sources.EventKind,
            in_flight: *bool,
        ) LaneFault!void {
            if (!in_flight.*)
                return;
            in_flight.* = false;
            const ring = self.runtime_ring orelse return;
            const generation = self.completion_registrations[registration_index].generation;
            try self.runtime_events.queuePollCancel(
                ring,
                .{ .kind = .worker_poll_cancel, .index = registration_index, .generation = generation },
                .{ .kind = kind, .index = registration_index, .generation = generation },
            );
        }

        /// Cancels every poll of registration `registration_index` still in
        /// flight and moves it to its next generation, so a completion that
        /// was already on its way reads as stale.
        fn cancelPolls(self: *Self, registration_index: u32) LaneFault!void {
            const registration = &self.completion_registrations[registration_index];
            try cancelPoll(self, registration_index, .worker_completion, &registration.poll_registered);
            try cancelPoll(self, registration_index, .worker_control, &registration.control_poll_registered);
            try cancelPoll(self, registration_index, .worker_fs_fault, &registration.fs_fault_poll_registered);
            try cancelPoll(self, registration_index, .worker_pidfd, &registration.pidfd_poll_registered);
            try cancelPoll(self, registration_index, .worker_control_writable, &registration.control_writable_poll_registered);
            try cancelPoll(self, registration_index, .worker_payload_credit, &registration.ingress_payload_credit_poll_registered);
            registration.generation = nextGeneration(registration.generation);
        }

        pub fn registrationAt(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            if (registration_index >= self.completion_registration_count)
                return error.InvalidCompletionRegistration;
            const registration = &self.completion_registrations[registration_index];
            if (!registration.inUse())
                return error.InvalidCompletionRegistration;
            return registration;
        }

        /// Stops reading the worker of registration `registration_index`:
        /// cancels its polls, ends the tenure with the ring account and the
        /// forwarding losses it kept, and re-arms what the registration still
        /// needs for this lane's own requests.
        fn stopReading(self: *Self, registration_index: u32) LaneFault!void {
            const registration = &self.completion_registrations[registration_index];
            if (!registration.reading())
                return;
            try cancelPolls(self, registration_index);
            registration.endTenure();
            if (registration.inflight_request_len != 0)
                _ = try armWorkerPolls(self, registration_index);
        }

        /// Frees a registration that neither reads its worker nor holds a
        /// request on it, cancelling the polls it still has in flight. One
        /// whose worker fault waits on the lane's death queue stays, with the
        /// reason and the death notice that path needs, until the path runs
        /// (`worker_fault.processDeferredWorkerFaults`).
        pub fn releaseRegistrationIfIdle(self: *Self, registration_index: u32) LaneFault!void {
            const registration = &self.completion_registrations[registration_index];
            if (!registration.inUse() or registration.reading() or registration.inflight_request_len != 0)
                return;
            if (registration.death_queued)
                return;
            try cancelPolls(self, registration_index);
            const generation = registration.generation;
            registration.* = .{ .generation = generation };
        }

        /// Gives this lane's reader role over a dead `worker` back to its
        /// pool. A role granted to this lane with no tenure registered here
        /// is named only in the pool, and only this lane can end it.
        pub fn endReading(self: *Self, registration_index: u32, worker: *WorkerRecord) LaneFault!void {
            const registration = &self.completion_registrations[registration_index];
            if (registration.worker == worker and registration.reading()) {
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
            const registration = &self.completion_registrations[registration_index];
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
    };
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}
