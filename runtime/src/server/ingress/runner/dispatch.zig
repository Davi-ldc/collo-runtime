//! The dispatch of an ingress lane's requests to worker slots and the sends
//! that follow it, on the lane thread that owns the request: binding a
//! request to a slot its pool gave it, its entry in the worker's request
//! table, the `DispatchWork` its `request_begin` carries with the egress
//! token minted for it, the `request_reset` of a stream the client gave up,
//! the order of a request's sends, and the sends that wait for room in a
//! worker's control socket or payload ring. The request's body chunks go
//! out from `request_body.zig` under the rules below.
//!
//! Invariants:
//! - A request reaches a worker only through `dispatchWithHead`: at
//!   admission when its pool has a free slot, and later when the pool hands
//!   it one (`dispatch_ready`, or a slot this lane gives back to its own
//!   waiter in `request_finish.zig`). From there it holds the worker slot
//!   until its finish gives the slot back. Its wheel entry stays at its
//!   deadline until the begin reaches the worker, then moves to the deadline
//!   plus `hard_timeout_grace_ns`: by then a healthy worker answered 504
//!   itself.
//! - Every send toward a worker goes through the worker's record (its control
//!   socket, `send_mutex` and payload ring), so a lane sends to workers that
//!   another lane reads.
//! - A send that would block is backpressure and never a fault. Its bytes
//!   wait on the request (`RequestSlot.send_blocked`) under the request's
//!   deadline, behind a writability poll on the worker's control socket or,
//!   for room in the worker's payload ring, behind the `payload_credit` wake
//!   the worker's reader raises (`request_body.zig`), and the request's later
//!   sends queue behind them in order: its begin, a reset, then its stream's
//!   buffered body.
//! - A send that fails for the worker's doing stops the request's sends. Met
//!   inside a stream handler, it queues the worker's death path for after the
//!   handler (`worker_fault.deferWorkerFault`), since that path drives other
//!   connections; the loop handler that retries blocked sends runs it at once
//!   (`flushBlockedSends`).
//! - A request's egress token comes from the lane's own lease (`Lease.mint`
//!   in `server/gateway/lease.zig`), which the loop renews at the start of
//!   each pass (`ring_driver.zig`), so a dispatch never takes the manager's
//!   mutex and never waits for the gateway. The worker's egress session is
//!   read only through `Supervisor.workerEgress` in
//!   `server/supervisor/supervisor.zig`, since the launcher rewrites it under
//!   the pool's mutex when it reattaches the worker to a new gateway.

const std = @import("std");
const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const ipc = @import("collo_ipc");
const policy = @import("collo_egress_gateway").policy;
const fault = @import("../fault.zig");
const completions = @import("../completions.zig");
const admission = @import("admission.zig");
const deadline_driver = @import("deadline_driver.zig");
const request_body = @import("request_body.zig");
const request_finish = @import("request_finish.zig");
const request_slot_mod = @import("request_slot.zig");
const ring_driver = @import("ring_driver.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");

const worker_shared_page = @import("collo_worker_state").page;

const pool = supervision.pool;
const WorkerRecord = supervision.worker_table.Record;
const RequestSlot = request_slot_mod.RequestSlot;
const DispatchHead = request_slot_mod.DispatchHead;
const ParkedBegin = request_slot_mod.ParkedBegin;
const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;

/// How a send toward a worker ended.
pub const Sent = union(enum) {
    sent,
    /// The worker's control socket is full: its writability poll wakes the
    /// retry.
    socket_full,
    /// The worker's payload ring is full: the reader's `payload_credit` wake
    /// retries it (`request_body.zig`).
    ring_full,
    /// The send failed for the worker's doing.
    fault: fault.WorkerFaultReason,
};

/// How a waiting request used a worker slot handed to it (`useHandoff`).
pub const HandoffUse = enum {
    dispatched,
    /// The request ended without the slot, which goes back to the pool.
    unused,
    /// The worker left service after the handoff: the slot goes back, and
    /// the request asks its pool again (`admission.placeWaitingRequest`).
    worker_dead,
};

/// What the egress token of the request in `slot` says when it is minted
/// for worker session `session_id`: the request's identity, its deadline,
/// and the policy and fetch budget of `egress/gateway/policy.zig`. Pure and
/// file-level, so the mapping is testable without a lane.
pub fn requestTokenFields(slot: *const RequestSlot, session_id: u64) ipc.egress_token.Fields {
    return .{
        .kind = .request,
        // Every route maps to the one entry of the gateway's policy table.
        .policy_id = policy.public_https_id,
        .budget = policy.production.max_fetches_per_request,
        .session_id = session_id,
        .request_id = slot.request_id,
        .request_generation = slot.request_key.generation,
        .deadline_monotonic_ns = slot.deadline_ns,
    };
}

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const RequestBody = request_body.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);
        const RingDriver = ring_driver.Methods(Self);
        const WorkerFault = worker_fault.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// Dispatches the waiting request in `request_slot` on `worker_slot`
        /// of `worker`, which its pool handed to it (`dispatch_ready`). The
        /// caller found the request waiting under the key the handoff names
        /// (`admission.waitingRequestSlot`) and discharged the handoff's
        /// reader grant.
        /// A request whose stream went away ends here and the slot goes back
        /// to the pool; a worker that left service since the handoff gives
        /// the slot back, and the request asks its pool again.
        pub fn dispatchToWorker(
            self: *Self,
            request_slot: u32,
            worker: *WorkerRecord,
            worker_slot: pool.Slot,
        ) LaneFault!void {
            switch (try useHandoff(self, request_slot, worker, worker_slot)) {
                .dispatched => {},
                .unused => try RequestFinish.releaseWorkerSlot(self, worker, worker_slot),
                .worker_dead => {
                    try RequestFinish.releaseWorkerSlot(self, worker, worker_slot);
                    try Admission.placeWaitingRequest(self, request_slot);
                },
            }
        }

        /// `dispatchToWorker` without giving an unused slot back, which the
        /// caller does: `request_finish.releaseWorkerSlot` hands a freed
        /// slot to this lane's own waiters through here without recursing.
        pub fn useHandoff(
            self: *Self,
            request_slot: u32,
            worker: *WorkerRecord,
            worker_slot: pool.Slot,
        ) LaneFault!HandoffUse {
            const slot = self.requests.get(request_slot) orelse return error.RequestSlotVacant;
            if (!slot.waiting())
                return error.RequestSlotVacant;
            // A slot handed on before `markDead` can reach its lane after it.
            const view = self.service.supervisor.poolFor(worker.definition_index).inspect(worker) orelse
                return .worker_dead;
            if (view.state != .live)
                return .worker_dead;
            const runtime = Admission.requestConnection(self, slot) orelse {
                try RequestFinish.finishRequest(self, request_slot, .stream_gone);
                return .unused;
            };
            if (!runtime.isOpen() or (runtime.h2StreamState(slot.ingress_channel_id) orelse .vacant) != .preparing) {
                try RequestFinish.finishRequest(self, request_slot, .stream_gone);
                return .unused;
            }
            // A request that waits owns its head (`admission.placeRequest`).
            const owned = slot.head orelse return error.RequestSlotVacant;
            try dispatchWithHead(self, request_slot, worker, worker_slot, owned.head);
            return .dispatched;
        }

        /// The one dispatch: binds the waiting request in `request_slot` to
        /// `worker_slot` of `worker`, records its request table entry, keys
        /// its wheel entry to the worker, activates its stream, mints its
        /// egress token and sends its `request_begin`, which moves the wheel
        /// entry to the hard-timeout backstop, then the body its stream
        /// buffered while it waited. `head` may point into the request's own
        /// copy, which this frees once the begin is sent or parked. A send
        /// that would block parks the begin behind the worker's writability
        /// poll; a send that fails is the worker's fault, whose death path
        /// ends the request with the worker's others.
        pub fn dispatchWithHead(
            self: *Self,
            request_slot: u32,
            worker: *WorkerRecord,
            worker_slot: pool.Slot,
            head: DispatchHead,
        ) LaneFault!void {
            const slot = &self.requests.entries[request_slot];
            std.debug.assert(slot.waiting());
            // Every caller saw the request's stream `.preparing` on this
            // thread just before.
            const runtime = Admission.requestConnection(self, slot) orelse return error.InvalidH2ConnectionState;
            const now = self.monotonicNowNs();
            const worker_key = worker.key();
            const registration_index = try WorkerRegistration.registrationFor(self, worker);

            // From here the request holds the worker slot, and its finish
            // gives the slot back.
            slot.worker = worker;
            slot.worker_slot = worker_slot;
            slot.worker_key = worker_key;
            try WorkerRegistration.attachRequest(self, registration_index, slot.request_key);
            // Until its begin reaches the worker, the request ends at its own
            // deadline: a worker that never heard of it cannot answer it
            // (`deadline_driver.expireRequest`).
            try moveWheelEntry(self, slot, slot.deadline_ns, now);
            runtime.h2ActivateStream(slot.ingress_channel_id, slot.request_key, slot.request_id) catch |err| switch (err) {
                error.Http2UnknownStream,
                error.Http2StreamStateMismatch,
                => return error.InvalidH2ConnectionState,
            };
            self.lane.recordDispatchHandoff();

            var accounting_flags: u32 = 0;
            // A request that waited (it owns its head) for a worker launched
            // after it arrived rode that cold start.
            if (slot.head != null and worker.created_mono_ns >= slot.admitted_ns) {
                accounting_flags |= worker_shared_page.CompletedRecordFlags.cold_start;
                slot.access.cold_start = true;
                slot.access.cold_start_ns = worker.boot_work_ns;
                slot.access.cold_start_blocked_ns = now -| slot.admitted_ns;
            }
            // Recorded before the worker can hear of the request, so its
            // usage record never reaches a drain ahead of the entry
            // (`server/supervisor/request_table.zig`).
            try worker.requests.record(.{
                .request_id = slot.request_id,
                .request_key = slot.request_key,
                .route = slot.route.route,
                .accounting_flags = accounting_flags,
                .started_mono_ns = now,
            });
            var dispatch_work = ipc.DispatchWorkView{
                .request_id = slot.request_id,
                .request_lane_id = slot.request_key.lane_id,
                .request_slot = slot.request_key.slot,
                .request_generation = slot.request_key.generation,
                .worker_id = worker_key.worker_id,
                .worker_generation = worker_key.worker_generation,
                .accounting_flags = accounting_flags,
                .authority = head.authority,
                .deadline_monotonic_ns = slot.deadline_ns,
                .method = head.method,
                .path = head.path,
                .raw_query = head.raw_query,
                .request_headers = head.request_headers,
                .body_framing = head.body_framing,
                .route_captures = head.route_captures,
                // The worker serves every route of its definition and finds
                // this one at the same index in the route table WorkerInit
                // carried (`server/routes/artifacts.zig`).
                .route_index = slot.route.route,
            };
            const egress = self.service.supervisor.workerEgress(worker);
            if (egress.session_id != 0) {
                dispatch_work.egress_token = self.egress_lease.mint(
                    egress.generation,
                    requestTokenFields(slot, egress.session_id),
                );
                // The slot keeps the session of a token the request carries,
                // whose end its finish notes (`request_finish.zig`); `none`
                // leaves nothing to end.
                if (!ipc.egress_token.isNone(&dispatch_work.egress_token)) {
                    slot.egress_gateway_generation = egress.generation;
                    slot.egress_gateway_session_id = egress.session_id;
                }
            }

            const payload = ipc.encodeDispatchWorkInto(self.ipc_send_scratch, &dispatch_work) catch |err| {
                std.log.err("ingress lane {d} built a dispatch its encoder refuses: {s}", .{
                    self.listener_index,
                    @errorName(err),
                });
                return error.WorkerSendMisuse;
            };
            const descriptor = ipc.ingress_channel.Descriptor.requestBegin(
                slot.identity(),
                slot.ingress_channel_id,
                0,
                @intCast(payload.len),
                @intCast(head.request_headers.len),
                head.body_framing == .none,
            );
            const begin = try sendBegin(self, worker, descriptor, payload);
            // The begin is sent, parked with its own copy of the payload, or
            // dropped with the worker, so the head is done with. `head` may
            // point into it, and is not read again.
            freeOwnedHead(slot);
            switch (begin) {
                .sent => try beginReachedWorker(self, slot),
                .socket_full, .ring_full => {
                    slot.parked_begin = ParkedBegin.init(self.service.allocator, descriptor, payload) catch |err| switch (err) {
                        error.OutOfMemory => return failSend(self, slot, .allocation_failed),
                    };
                    slot.send_blocked = .socket;
                    try RingDriver.armWorkerControlWritable(self, registration_index);
                    return;
                },
                .fault => |reason| return failSend(self, slot, reason),
            }
            switch (try RequestBody.flushPendingBody(self, request_slot)) {
                .ok => {},
                .would_block => try armSendPolls(self, slot),
                .fault => |reason| try failSend(self, slot, reason),
            }
        }

        /// Moves a dispatched request's wheel entry to `deadline_ns`, under
        /// its worker's key, which a dispatched request's entry carries. The
        /// entry only moves later, so the timerfd keeps its wake
        /// (`admission.insertWheelEntry`).
        fn moveWheelEntry(self: *Self, slot: *RequestSlot, deadline_ns: u64, now: u64) LaneFault!void {
            try self.lane.armRequestDeadline(
                &slot.deadline,
                slot.request_key,
                slot.connection_key,
                slot.worker_key,
                deadline_ns,
                now,
            );
        }

        /// Records that the request's `request_begin` is in its worker's
        /// socket, and moves its wheel entry from its deadline to the
        /// deadline plus `hard_timeout_grace_ns`: the worker now answers 504
        /// itself when the deadline passes, and the entry is the backstop that
        /// faults one that has not by then.
        fn beginReachedWorker(self: *Self, slot: *RequestSlot) LaneFault!void {
            slot.begin_sent = true;
            const backstop_ns = deadline_driver.effectiveHardTimeoutDeadline(slot.deadline_ns, self.service.hard_timeout_grace_ns);
            try moveWheelEntry(self, slot, backstop_ns, self.monotonicNowNs());
        }

        fn freeOwnedHead(slot: *RequestSlot) void {
            if (slot.head) |*owned| {
                owned.deinit();
                slot.head = null;
            }
        }

        /// Tells the worker of the dispatched request in `request_slot` that
        /// its client stream is gone (`request_reset`), so it can stop; the
        /// request stays until the worker completes it. A request whose begin
        /// never reached the worker ends here instead, and its slot goes
        /// back. A reset that would block waits behind the worker's
        /// writability poll, and the stream's body is dropped either way.
        pub fn cancelRequestToWorker(self: *Self, request_slot: u32, error_code: u32) LaneFault!void {
            const slot = &self.requests.entries[request_slot];
            if (!slot.dispatched())
                return error.RequestSlotVacant;
            switch (slot.send_blocked) {
                // The worker's death path ends the request.
                .failed => return,
                .none, .socket, .ring => {},
            }
            if (!slot.begin_sent)
                return RequestFinish.finishRequest(self, request_slot, .stream_gone);
            switch (try sendReset(self, slot, error_code)) {
                .sent => slot.send_blocked = .none,
                .socket_full, .ring_full => {
                    slot.parked_reset = error_code;
                    slot.send_blocked = .socket;
                    try armSendPolls(self, slot);
                },
                .fault => |reason| try failSend(self, slot, reason),
            }
        }

        /// Retries the sends of this lane's requests on the worker of
        /// registration `registration_index` that wait for room, after the
        /// writability poll on the worker's control socket fired or the
        /// worker freed room in its payload ring; it then arms the polls the
        /// requests still wait on. A request's sends go out in their order:
        /// its begin, a reset, then its stream's buffered body. A send that
        /// fails for the worker's doing runs the death path here, outside
        /// any stream handler.
        pub fn flushBlockedSends(self: *Self, registration_index: u32) LaneFault!void {
            _ = try WorkerRegistration.registrationAt(self, registration_index);
            if (try retryBlockedSends(self, registration_index)) |reason|
                return WorkerFault.faultWorker(self, registration_index, reason);
            try WorkerRegistration.armWorkerPolls(self, registration_index);
        }

        /// Handles this lane's `payload_credit` wake: a worker freed room in
        /// a payload ring one of this lane's requests waits on. The wake does
        /// not say which worker, so every registration with a send parked on
        /// a full ring retries its blocked sends.
        pub fn retryRingBlockedSends(self: *Self) LaneFault!void {
            for (self.registrations.touched(), 0..) |*registration, index| {
                if (!registration.inUse() or !waitsOnRing(self, registration))
                    continue;
                try flushBlockedSends(self, @intCast(index));
            }
        }

        /// Whether one of this lane's requests on the worker of
        /// `registration` waits for room in its payload ring.
        fn waitsOnRing(self: *Self, registration: *const completions.Registration) bool {
            for (registration.inflight_request_keys[0..registration.inflight_request_len]) |request_key| {
                const request_slot = Admission.findRequestSlot(self, request_key) orelse continue;
                if (self.requests.entries[request_slot].send_blocked == .ring)
                    return true;
            }
            return false;
        }

        /// Tries, in order, the sends of this lane's requests on the worker
        /// of registration `registration_index` that wait for room, and
        /// returns the fault of the first one that failed for the worker's
        /// doing.
        fn retryBlockedSends(self: *Self, registration_index: u32) LaneFault!?fault.WorkerFaultReason {
            const registration = &self.registrations.entries[registration_index];
            var request_keys: [completions.max_worker_inflight_requests]lifecycle.RequestKey = undefined;
            const request_count = registration.copyInflight(&request_keys);
            for (request_keys[0..request_count]) |request_key| {
                const request_slot = Admission.findRequestSlot(self, request_key) orelse continue;
                switch (self.requests.entries[request_slot].send_blocked) {
                    .none, .failed => continue,
                    .socket, .ring => {},
                }
                switch (try flushRequestSends(self, request_slot)) {
                    .ok, .would_block => {},
                    .fault => |reason| return reason,
                }
            }
            return null;
        }

        /// Sends what the dispatched request in `request_slot` has waiting,
        /// in order, until a send would block again or fails.
        pub fn flushRequestSends(self: *Self, request_slot: u32) LaneFault!WorkerOutcome {
            const slot = &self.requests.entries[request_slot];
            const worker = slot.worker orelse return error.RequestSlotVacant;
            if (slot.parked_begin) |*parked| {
                switch (try sendBegin(self, worker, parked.descriptor, parked.payload)) {
                    .sent => {
                        parked.deinit();
                        slot.parked_begin = null;
                        try beginReachedWorker(self, slot);
                    },
                    .socket_full, .ring_full => {
                        slot.send_blocked = .socket;
                        return .would_block;
                    },
                    .fault => |reason| return .{ .fault = reason },
                }
            }
            if (slot.parked_reset) |error_code| {
                switch (try sendReset(self, slot, error_code)) {
                    .sent => {
                        // The reset ends the request's body.
                        slot.parked_reset = null;
                        slot.send_blocked = .none;
                        return .ok;
                    },
                    .socket_full, .ring_full => {
                        slot.send_blocked = .socket;
                        return .would_block;
                    },
                    .fault => |reason| return .{ .fault = reason },
                }
            }
            slot.send_blocked = .none;
            return RequestBody.flushPendingBody(self, request_slot);
        }

        /// Stops the sends of the request in `slot` after one failed for its
        /// worker's doing, and queues the worker's death path for when the
        /// handler running now returns (`worker_fault.deferWorkerFault`);
        /// that path ends the request with the worker's others.
        pub fn failSend(self: *Self, slot: *RequestSlot, reason: fault.WorkerFaultReason) LaneFault!void {
            if (slot.send_blocked == .failed)
                return;
            slot.send_blocked = .failed;
            if (slot.parked_begin) |*parked| {
                parked.deinit();
                slot.parked_begin = null;
            }
            slot.parked_reset = null;
            const registration_index = WorkerRegistration.findCompletionRegistrationIndex(self, slot.worker_key) orelse
                return error.WorkerCompletionRegistrationNotFound;
            try WorkerFault.deferWorkerFault(self, registration_index, reason);
        }

        /// Arms the polls the worker of the dispatched request in `slot`
        /// needs for the sends its requests wait on. A send parked on the
        /// payload ring needs none: it registered for the reader's wake
        /// before it gave up (`request_body.zig`).
        pub fn armSendPolls(self: *Self, slot: *const RequestSlot) LaneFault!void {
            try WorkerRegistration.armWorkerPollsFor(self, slot);
        }

        /// Sends a request's `request_begin` with its DispatchWork payload.
        /// The record's scratch holds the packet, so the send takes
        /// `Record.send_mutex`.
        fn sendBegin(
            self: *Self,
            worker: *WorkerRecord,
            descriptor: ipc.ingress_channel.Descriptor,
            payload: []const u8,
        ) LaneFault!Sent {
            const send_error = send: {
                worker.send_mutex.lock();
                defer worker.send_mutex.unlock();
                ipc.ingress_channel.sendDescriptorPayload(
                    worker.handle.control_fd,
                    descriptor,
                    payload,
                    worker.dispatch_send_scratch,
                ) catch |err| break :send err;
                return .sent;
            };
            return sendResult(self, worker, send_error);
        }

        /// Sends a `request_reset`. A reset carries no payload and goes out
        /// as one SEQPACKET datagram encoded in the lane's scratch, which
        /// the kernel writes whole, so it takes no lock.
        fn sendReset(self: *Self, slot: *const RequestSlot, error_code: u32) LaneFault!Sent {
            const worker = slot.worker.?;
            ipc.ingress_channel.sendDescriptorPayload(
                worker.handle.control_fd,
                ipc.ingress_channel.Descriptor.requestReset(slot.identity(), slot.ingress_channel_id, error_code),
                "",
                self.ipc_send_scratch,
            ) catch |err| return sendResult(self, worker, err);
            return .sent;
        }

        /// Sorts a failed send toward `worker`: a full ring or socket is
        /// backpressure, a failure of the worker's doing is its fault, and a
        /// message the lane built wrong stops the lane.
        pub fn sendResult(
            self: *Self,
            worker: *const WorkerRecord,
            err: (fault.LaneFault || fault.WorkerSendError),
        ) LaneFault!Sent {
            if (err == error.IngressSharedPayloadRingFull)
                return .ring_full;
            const outcome = fault.classifyWorkerError(.{ .send = err }) catch |lane_fault| {
                std.log.err("ingress lane {d} send to worker_id={d} failed: {s}", .{
                    self.listener_index,
                    worker.id,
                    @errorName(err),
                });
                return lane_fault;
            };
            return switch (outcome) {
                // Neither left the bytes with the worker.
                .ok, .would_block => .socket_full,
                .fault => |reason| .{ .fault = reason },
            };
        }
    };
}
