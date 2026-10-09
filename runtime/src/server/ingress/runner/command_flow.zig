//! An ingress lane's commands, on the lane thread: the drain of the lane's
//! queue and the handler of each command (the queue is `commands.zig`, the
//! payloads and their protocol `lane_commands.zig`), the wake bits that
//! share the queue's eventfd (`ring_driver.takeWakeBits`), and the reader
//! role the lane gives up when another lane or the reaper asks for it, or
//! when the lane stops.
//!
//! A command waits in the queue while its subject moves on, so each handler
//! checks the keys the command carries against the lane's own state before
//! it acts, and a command whose request or worker registration is gone gives
//! back what it holds and does nothing else. Whether a worker is still in
//! service is read from its pool (`Pool.inspect`), not from the order in
//! which commands arrive: `markDead` precedes every `worker_died` post, so a
//! slot that travelled while its worker died finds the death in the pool even
//! when the notice is still behind it in the queue.
//!
//! Handlers run one at a time. The work each command starts (a dispatch, a
//! finish, a death path) belongs to the flow files that own it:
//! `dispatch.zig`, `request_finish.zig`, `worker_fault.zig`,
//! `worker_registration.zig`, `h2_worker_ipc.zig` and
//! `worker_completions.zig`.

const ipc = @import("collo_ipc");

const commands = @import("../commands.zig");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const lane_commands = @import("../lane_commands.zig");
const supervision = @import("collo_server_supervisor");
const admission = @import("admission.zig");
const dispatch = @import("dispatch.zig");
const h2_worker_ipc = @import("h2_worker_ipc.zig");
const request_finish = @import("request_finish.zig");
const ring_driver = @import("ring_driver.zig");
const worker_completions = @import("worker_completions.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");

const LaneFault = fault.LaneFault;
const pool = supervision.pool;
const WorkerRecord = supervision.worker_table.Record;

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const Completions = worker_completions.Methods(Self);
        const Dispatch = dispatch.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);
        const RingDriver = ring_driver.Methods(Self);
        const WorkerFault = worker_fault.Methods(Self);
        const WorkerIpc = h2_worker_ipc.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// Loop handler: reads the command eventfd, runs the retries the wake
        /// bits raised since ask for, then the commands queued now. The
        /// eventfd goes first: a command posted or a bit raised meanwhile has
        /// written its own wake and waits for the next call.
        pub fn handleCommands(self: *Self) LaneFault!void {
            _ = try self.lane.command_queue.drainWake();
            try RingDriver.takeWakeBits(self);
            var remaining = self.lane.command_queue.pending();
            while (remaining != 0) : (remaining -= 1) {
                var command = self.lane.command_queue.dequeue() orelse return;
                defer command.deinit();
                try runCommand(self, &command);
            }
        }

        /// Gives up this lane's tenure over the worker of
        /// `registration_index` when the pool lets it go
        /// (`Pool.transferReader`), and returns the pool's answer, which
        /// `applyReaderTransfer` has acted on: the lane stops reading unless
        /// the role was kept. A live worker's role goes only with nothing
        /// held of its ring, because the next reader decodes from the ring's
        /// read cursor: when the worker is idle, the payloads still held are
        /// ones whose answer was lost, so they are freed first, in ring
        /// order, and the pool is asked again, all while the role is still
        /// this lane's.
        pub fn giveUpTenure(self: *Self, registration_index: u32) LaneFault!pool.Transfer {
            const registration = &self.registrations.entries[registration_index];
            const tenure = registration.tenure orelse return .stale;
            const worker = registration.worker orelse return error.InvalidCompletionRegistration;
            const worker_pool = self.service.supervisor.poolFor(worker.definition_index);
            var transfer = worker_pool.transferReader(worker, tenure, readerHolds(registration));
            if (transfer == .free_held_payloads) {
                try freeAbandonedRingPayloads(self, registration_index);
                transfer = worker_pool.transferReader(worker, tenure, readerHolds(registration));
            }
            try WorkerRegistration.applyReaderTransfer(self, registration_index, transfer);
            switch (transfer) {
                .vacated, .retire => self.lane.counters.reader_tenures_released += 1,
                .stale, .kept, .free_held_payloads => {},
            }
            return transfer;
        }

        /// Gives back what the commands still queued when the lane tears
        /// down hold for others: each `dispatch_ready`'s slot, with the reader
        /// grant it carried (`request_finish.returnHandoff`), each forwarded
        /// descriptor's window unit, with a ring payload's answer so its
        /// reader frees the bytes, and each answer's window unit. The lane
        /// takes no post any more, so the queue only empties. The rest hold
        /// nothing beyond their memory, which `Command.deinit` frees.
        pub fn returnQueuedHandoffs(self: *Self) LaneFault!void {
            var remaining = self.lane.command_queue.pending();
            while (remaining != 0) : (remaining -= 1) {
                var command = self.lane.command_queue.dequeue() orelse return;
                defer command.deinit();
                switch (command) {
                    .dispatch_ready => |ready| try RequestFinish.returnHandoff(self, ready.worker, ready.slot, ready.reader),
                    .forwarded_descriptor => |*forwarded| try WorkerIpc.abandonForwardedDescriptor(self, forwarded),
                    .payload_consumed => |consumed| try WorkerIpc.releaseForwardUnit(self, consumed.worker),
                    .empty,
                    .worker_died,
                    .dispatch_failed,
                    .forwarded_completion,
                    .release_worker,
                    .shutdown,
                    => {},
                }
            }
        }

        fn runCommand(self: *Self, command: *commands.Command) LaneFault!void {
            switch (command.*) {
                .empty, .shutdown => {},
                .worker_died => |died| try handleWorkerDied(self, died),
                .dispatch_ready => |ready| try handleDispatchReady(self, ready),
                .dispatch_failed => |failed| try handleDispatchFailed(self, failed),
                // Borrowed; the drain frees the command after the handler.
                .forwarded_descriptor => |*forwarded| try applyForwardedDescriptor(self, forwarded),
                .forwarded_completion => |forwarded| try Completions.applyForwardedCompletion(self, forwarded),
                .payload_consumed => |consumed| try WorkerIpc.handlePayloadConsumed(self, consumed),
                .release_worker => |release| try handleReleaseWorker(self, release),
            }
        }

        /// The holder side of a death another lane, the reaper or the metrics
        /// thread saw: `faultWorker` finds the worker already dead in its
        /// pool, finishes this lane's requests on it and gives up the tenure
        /// if this lane reads it. A lane with no request on the worker that
        /// does not read it has nothing to do.
        fn handleWorkerDied(self: *Self, died: commands.WorkerDied) LaneFault!void {
            const registration_index = WorkerRegistration.findCompletionRegistrationIndex(self, died.worker_key) orelse {
                self.lane.counters.stale_commands += 1;
                return;
            };
            try WorkerFault.faultWorker(self, registration_index, died.reason);
        }

        /// A slot handed to a waiting request of this lane. The reader grant
        /// is discharged first, always, because the pool already counts this
        /// lane as the worker's reader or asked it to fetch the role. A
        /// worker that left service while the slot travelled is not read: a
        /// role it granted goes straight back, and its own death path ends
        /// another lane's. The request is dispatched when it still waits
        /// (`dispatchToWorker` gives the slot back and asks the pool again
        /// when the worker is gone); otherwise the slot goes back to the
        /// pool, which may hand it on.
        fn handleDispatchReady(self: *Self, ready: lane_commands.DispatchReady) LaneFault!void {
            const worker = ready.worker;
            const worker_pool = self.service.supervisor.poolFor(worker.definition_index);
            // The travelling slot keeps the worker in the table.
            const live = if (worker_pool.inspect(worker)) |view| view.state == .live else false;
            if (live) {
                try WorkerRegistration.dischargeReaderGrant(self, worker, ready.reader);
            } else switch (ready.reader) {
                .you_become_reader => |epoch| returnTenure(self, worker, .{
                    .lane = self.lane.lane_id,
                    .epoch = epoch,
                }),
                .already, .transfer_from => {},
            }
            const request_index = Admission.waitingRequestSlot(self, ready.request_key) orelse {
                self.lane.counters.handoffs_returned += 1;
                return RequestFinish.releaseWorkerSlot(self, worker, ready.slot);
            };
            try Dispatch.dispatchToWorker(self, request_index, worker, ready.slot);
        }

        /// A waiting request no worker can serve (`Pool.takeStranded`): 503,
        /// unless the request already ended.
        fn handleDispatchFailed(self: *Self, failed: lane_commands.DispatchFailed) LaneFault!void {
            const request_index = Admission.waitingRequestSlot(self, failed.request_key) orelse {
                self.lane.counters.stale_commands += 1;
                return;
            };
            self.lane.counters.waiters_stranded += 1;
            try RequestFinish.finishRequest(self, request_index, .unserved);
        }

        /// Applies a descriptor the worker's reader forwarded. One that shows
        /// the worker faulty runs the death path here: through this lane's
        /// registration of the worker when it has requests on it, and
        /// otherwise as a death seen elsewhere, which tells the lanes that
        /// hold or read the worker.
        fn applyForwardedDescriptor(self: *Self, forwarded: *lane_commands.ForwardedDescriptor) LaneFault!void {
            switch (try WorkerIpc.handleForwardedDescriptor(self, forwarded)) {
                .ok, .would_block => {},
                .fault => |reason| {
                    if (WorkerRegistration.findCompletionRegistrationIndex(self, forwarded.worker_key)) |registration_index|
                        return WorkerFault.faultWorker(self, registration_index, reason);
                    try WorkerFault.faultWorkerSeenElsewhere(self, forwarded.worker, forwarded.worker_key, reason);
                },
            }
        }

        /// The reader role asked for by a lane that took a slot of the idle
        /// worker, or by the reaper retiring it. Only the tenure the command
        /// names is given up, and only while the worker is idle
        /// (`Pool.transferReader`).
        fn handleReleaseWorker(self: *Self, release: lane_commands.ReleaseWorker) LaneFault!void {
            const registration_index = WorkerRegistration.findCompletionRegistrationIndex(self, release.worker_key) orelse {
                self.lane.counters.stale_commands += 1;
                return;
            };
            const tenure = self.registrations.entries[registration_index].tenure orelse {
                self.lane.counters.stale_commands += 1;
                return;
            };
            if (tenure.epoch != release.epoch) {
                self.lane.counters.stale_commands += 1;
                return;
            }
            _ = try giveUpTenure(self, registration_index);
        }

        /// Answers, oldest first, every ring payload the reader still holds,
        /// through the reader's own answer path, so the ring's read cursor
        /// moves over them in ring order. Their window units went with the
        /// answers that were lost, so none is released here.
        fn freeAbandonedRingPayloads(self: *Self, registration_index: u32) LaneFault!void {
            const registration = &self.registrations.entries[registration_index];
            const worker_key = registration.worker_key;
            const holds = &registration.ring_payloads;
            var abandoned: [ipc.ingress_channel.SharedPayloadHolds.capacity]lane_commands.RingRef = undefined;
            const count = holds.len;
            for (holds.entries[0..count], abandoned[0..count]) |entry, *ring|
                ring.* = .{ .offset = entry.offset, .len = entry.len };
            for (abandoned[0..count]) |ring|
                WorkerIpc.answerHeldPayload(self, worker_key, ring);
        }

        /// Gives back a tenure the pool granted over a worker that left
        /// service before this lane registered it. The slot this lane still
        /// holds keeps the worker unfinished, so the pool answers `.vacated`
        /// and the worker retires when its last slot comes back.
        fn returnTenure(self: *Self, worker: *WorkerRecord, tenure: pool.ReaderTenure) void {
            switch (self.service.supervisor.poolFor(worker.definition_index).transferReader(worker, tenure, .nothing)) {
                .stale, .kept, .free_held_payloads => {},
                .vacated => self.service.reaper.wakeForPidfdScan(),
                .retire => self.service.queueRetirement(worker),
            }
        }
    };
}

fn readerHolds(registration: *const completions.Registration) pool.ReaderHolds {
    return if (registration.ring_payloads.isEmpty()) .nothing else .ring_payloads;
}
