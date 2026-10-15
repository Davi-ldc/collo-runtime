//! A worker's descriptors on an ingress lane thread of the server. The
//! worker's reader (`server/supervisor/pool.zig`) decodes them from the
//! worker's control socket (`worker_control.zig`). A response descriptor for
//! a request of the reader's own lane goes onto that request's client stream
//! here, and a `request_done` finishes the request (`request_done.zig`);
//! a response descriptor for another lane's request travels to that lane as
//! `forwarded_descriptor` (`lane_commands.zig`), which applies it here as if
//! it had read it itself, and a `request_done` as `forwarded_request_done`.
//! The answer of a stream whose request ends without its response and the
//! worker's forwarding window are here too.
//!
//! - A descriptor is worker output, so it acts only on a request it names
//!   exactly: the request key of a live request dispatched to the sending
//!   worker, on that request's own stream, and the HTTP/2 layer checks the
//!   request id against the stream's record. A descriptor whose request ended
//!   or whose stream went away is a race and drops. Every other mismatch,
//!   every descriptor the stream cannot admit, and a body chunk past the
//!   request's credit window (`RequestSlot.response_credit`) are worker
//!   faults returned to the caller as `fault.WorkerOutcome`; the caller runs
//!   the death path, and nothing here marks a worker dead. Before it
//!   forwards one, the reader checks it against the worker's request table
//!   (`RequestTable.forwardCheck`): a request the table no longer holds, or
//!   whose `request_done` the reader already forwarded, drops the
//!   descriptor, and one the table holds under another key is a fault. The
//!   table marks a request's `request_done` forwarded once its post went in
//!   (`RequestTable.markDoneForwarded`), so the reader forwards at most one
//!   per request and nothing of the request after it.
//! - The forwarding window bounds the response descriptors and answers one
//!   worker's output holds in all lanes' queues to
//!   `limits.ingress.forwarded_commands_per_worker_max`
//!   (`Record.forwarded_in_queues`). Each forwarded response descriptor takes
//!   a unit before its post; the owner releases it once it applied or
//!   dropped the descriptor, or hands it on to the `payload_consumed` that
//!   answers a ring payload, which the reader releases. Every unit is
//!   released once, by whoever ends the command, a refused post and a lane's
//!   teardown included. A forwarded `request_done` takes no unit: the
//!   owner's reserve holds one per request in flight (`commands.zig`), so a
//!   full window never costs a worker that answered its request. The reader
//!   receives the worker's next packet only while a packet's worth of units
//!   fits (`windowHasRoom`); otherwise it stops reading the control socket
//!   (`Registration.window_blocked`), and the release that makes room raises
//!   its `window_reopened` wake. A drain that must read through, the last
//!   read of a dead worker or the grace backstop, ignores the window, and a
//!   response descriptor that finds it full drops as a refused post does.
//! - A ring payload stays in the worker's ring until its consumer is done
//!   with it. The reader accounts for every ring payload it decodes
//!   (`Registration.ring_payloads`), holds the ones it forwards until their
//!   owner answers `payload_consumed`, and frees ring bytes only over the
//!   answered prefix, in ring order. An owner answers every ring payload it
//!   was forwarded, used or not, before it drives the connection or finishes
//!   the request. The reader forwards a request's `request_done` after every
//!   descriptor of the request, and one lane's commands run in the order
//!   they were posted, so the answers reach the reader before the request's
//!   slot goes back to the pool, and a reader whose worker is idle holds
//!   nothing unless an answer was lost.
//! - Once a forwarded descriptor of a request is lost, the reader drops the
//!   rest of that response (`Registration.forward_loss`) but still forwards
//!   the request's `request_done`, so no client gets a response with a gap.
//!   The `request_done` ends the request: with 502 when its response head
//!   was the descriptor lost, and otherwise with its stream reset, since the
//!   response's end will never come (`request_finish.zig`). A `request_done`
//!   whose post is refused, which only an owner lane that stopped or a queue
//!   full past its reserve can do, leaves its request to the grace backstop.
//! - Whether a worker's response head went out is the lane's own HTTP/2
//!   record (`responseHeadQueued`), never a flag the worker wrote.

const std = @import("std");
const process = @import("collo_os").process;
const ipc = @import("collo_ipc");
const http_common = @import("collo_http");
const limits = @import("collo_limits");
const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const lane_commands = @import("../lane_commands.zig");
const server_responses = @import("../server_responses.zig");
const http2_writing = @import("../http2/writing.zig");
const admission = @import("admission.zig");
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const dispatch = @import("dispatch.zig");
const request_slot = @import("request_slot.zig");
const request_done = @import("request_done.zig");
const runner = @import("root.zig");

const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;
const WorkerFaultReason = fault.WorkerFaultReason;
const ConnectionSlot = connection_slot.Slot;
const RequestSlot = request_slot.RequestSlot;
const WorkerRecord = supervision.worker_table.Record;
const Descriptor = ipc.ingress_channel.Descriptor;
const Received = ipc.ingress_channel.Received;
const Op = ipc.ingress_channel.Op;

/// The units of a worker's forwarding window.
const window_units_max: u32 = limits.ingress.forwarded_commands_per_worker_max;
/// The units one packet can need: one per descriptor a packet carries.
const window_packet_units: u32 = ipc.ingress_channel.max_batch_descriptors;

comptime {
    std.debug.assert(window_packet_units <= window_units_max);
}

/// Whether `worker`'s forwarding window has room for one more packet's
/// descriptors. When it has not, `reader_lane` marks itself the window's
/// waiter and looks once more. The mark and the look, and a release's
/// decrement and its take of the mark (`releaseForwardUnit`), are all
/// sequentially consistent, so either this look sees the room a release
/// made or that release sees the mark and wakes the reader.
pub fn windowHasRoom(worker: *WorkerRecord, reader_lane: supervision.pool.LaneId) bool {
    if (windowRoom(worker))
        return true;
    worker.window_waiter.store(reader_lane + 1, .seq_cst);
    return windowRoom(worker);
}

fn windowRoom(worker: *WorkerRecord) bool {
    return worker.forwarded_in_queues.load(.seq_cst) + window_packet_units <= window_units_max;
}

/// Takes a unit of `worker`'s window for a descriptor about to be posted.
/// False, taking none, when the window is full, which only a drain that
/// reads through the window meets.
///
/// The count never passes the window, so every decrement is a release
/// (`releaseForwardUnit`), and the one that brings the count back within the
/// reading bound wakes the waiting reader. An add that overshot and took
/// itself back could make that step instead and wake nobody. Only the
/// worker's reader takes units, so an exchange fails only after a release
/// lowered the count, and the loop ends within the window's size; one still
/// failing then counts as a full window.
fn acquireForwardUnit(worker: *WorkerRecord) bool {
    var expected = worker.forwarded_in_queues.load(.seq_cst);
    for (0..window_units_max + 1) |_| {
        if (expected >= window_units_max)
            return false;
        expected = worker.forwarded_in_queues.cmpxchgStrong(expected, expected + 1, .seq_cst, .seq_cst) orelse
            return true;
    }
    return false;
}

/// What handling one packet of a worker leaves to the drain that read it.
pub const Handled = struct {
    /// `.ok`, or `.fault` with the worker's reason; never `.would_block`.
    outcome: WorkerOutcome = .ok,
    /// A connection the packet's responses went to cannot take more of a
    /// worker's response now (`hasBacklog`): the drain stops here and leaves
    /// the rest of the worker's output to the lane's next pass.
    yield: bool = false,
};

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const Done = request_done.Methods(Self);
        const Connection = connection_flow.Methods(Self);
        const Dispatch = dispatch.Methods(Self);

        /// The request a descriptor acts on and the connection its stream
        /// lives on.
        const Target = struct {
            runtime: *ConnectionSlot,
            active: *RequestSlot,
        };

        const Resolution = union(enum) {
            local: Target,
            /// The request ended or its stream went away: a race, so the
            /// descriptor drops.
            stale,
            fault: WorkerFaultReason,
        };

        /// Handles one descriptor the reader decoded from a single packet
        /// of the worker that `registration` reads: queues it onto its
        /// stream when the request is this lane's, or forwards it.
        pub fn handleWorkerDescriptor(
            self: *Self,
            registration: *completions.Registration,
            received: *Received,
        ) LaneFault!Handled {
            self.lane.counters.h2_worker_descriptors += 1;
            return handleReceived(self, registration, received);
        }

        /// Handles the descriptors of one batch packet in order, stopping at
        /// the first worker fault.
        pub fn handleWorkerBatch(
            self: *Self,
            registration: *completions.Registration,
            batch: *ipc.ingress_channel.ReceivedBatch,
        ) LaneFault!Handled {
            self.lane.counters.h2_worker_descriptor_batches += 1;
            self.lane.counters.h2_worker_descriptors += @intCast(batch.items.len);
            var yield = false;
            for (batch.items) |*received| {
                const handled = try handleReceived(self, registration, received);
                switch (handled.outcome) {
                    .ok => {},
                    .would_block, .fault => return handled,
                }
                yield = yield or handled.yield;
            }
            return .{ .yield = yield };
        }

        /// Applies a descriptor another lane's reader forwarded for a request
        /// of this lane, as `handleWorkerDescriptor` applies one this lane
        /// read, and ends the command's window unit once it is applied: a
        /// ring payload's answer takes it to the reader. Returns `.fault` when the descriptor shows the
        /// worker faulty; the caller runs the death path for
        /// `forwarded.worker_key`, which this lane may not read. The caller
        /// keeps `forwarded` and frees it (`ForwardedDescriptor.deinit`).
        pub fn handleForwardedDescriptor(
            self: *Self,
            forwarded: *lane_commands.ForwardedDescriptor,
        ) LaneFault!WorkerOutcome {
            const resolution = try resolveDescriptor(self, forwarded.worker_key, forwarded.descriptor);
            const target = switch (resolution) {
                .local => |target| target,
                .stale => {
                    self.lane.counters.stale_commands += 1;
                    try endForwardedUnit(self, forwarded);
                    return .ok;
                },
                .fault => |reason| {
                    try endForwardedUnit(self, forwarded);
                    return .{ .fault = reason };
                },
            };
            // An inline payload moves into `received` with the allocator that
            // holds it; a ring payload stays borrowed from the ring.
            var received: Received = .{
                .allocator = self.service.allocator,
                .descriptor = forwarded.descriptor,
                .payload_owned = false,
            };
            switch (forwarded.payload) {
                .none => {},
                .inline_bytes => |bytes| {
                    received.allocator = bytes.allocator;
                    received.payload = bytes.bytes;
                    received.payload_owned = true;
                    forwarded.payload = .none;
                },
                .ring => |ring| received.payload = heldRingPayload(target.active, ring) orelse {
                    try endForwardedUnit(self, forwarded);
                    return .{ .fault = .payload_ring_invalid };
                },
            }
            defer received.deinit();
            const outcome = try queueDescriptor(self, target, &received);
            // The descriptor copied any ring bytes it keeps into its chunk,
            // so the answer may let the reader free them.
            try endForwardedUnit(self, forwarded);
            return outcome;
        }

        /// Drops a forwarded descriptor the lane will never apply, at its
        /// teardown, ending its window unit: a ring payload's answer takes it
        /// to the reader, which frees the bytes in ring order instead of
        /// holding them until the worker idles.
        pub fn abandonForwardedDescriptor(
            self: *Self,
            forwarded: *const lane_commands.ForwardedDescriptor,
        ) LaneFault!void {
            try endForwardedUnit(self, forwarded);
        }

        /// Takes an owner's answer for a ring payload this lane forwarded:
        /// releases the answer's window unit, marks the payload answered and
        /// frees the ring bytes the answered prefix now covers. An answer
        /// that matches nothing this lane holds, for a worker it no longer
        /// reads, drops after the release.
        pub fn handlePayloadConsumed(
            self: *Self,
            consumed: lane_commands.PayloadConsumed,
        ) LaneFault!void {
            try releaseForwardUnit(self, consumed.worker);
            answerHeldPayload(self, consumed.worker_key, consumed.ring);
        }

        /// Marks the ring payload `ring` of the worker this lane reads as
        /// `worker_key` answered and frees the ring bytes the answered prefix
        /// now covers, or counts the answer as stale when nothing matches.
        pub fn answerHeldPayload(self: *Self, worker_key: lifecycle.WorkerKey, ring: lane_commands.RingRef) void {
            const registration = readingRegistration(self, worker_key) orelse {
                self.lane.counters.stale_commands += 1;
                return;
            };
            const freed = registration.ring_payloads.answer(ring.offset, ring.len) orelse {
                self.lane.counters.stale_commands += 1;
                return;
            };
            releaseRingBytes(registration, freed);
        }

        /// Releases a unit of `worker`'s forwarding window. The release that
        /// leaves room for a packet again raises the waiting reader's
        /// `window_reopened` wake (`windowHasRoom`).
        pub fn releaseForwardUnit(self: *Self, worker: *WorkerRecord) LaneFault!void {
            const previous = worker.forwarded_in_queues.fetchSub(1, .seq_cst);
            // Every unit is released once, so the count never underflows.
            std.debug.assert(previous != 0);
            if (previous != window_units_max - window_packet_units + 1)
                return;
            const waiter = worker.window_waiter.swap(0, .seq_cst);
            if (waiter == 0)
                return;
            try self.service.raiseLaneWake(waiter - 1, runner.wake.window_reopened);
        }

        /// Answers the client stream of a request that ends before its
        /// worker finished the response, at its deadline or its worker's
        /// death or fault, with the server response `response_id`, while no
        /// response head of the worker went out. After the head, the request
        /// leaving its stream ends it (`request_finish.leaveStream`): the
        /// stream delivers a buffered tail that carries END_STREAM and is
        /// reset otherwise, once, since nothing but PRIORITY may follow a
        /// stream's RST_STREAM (RFC 9113 §5.1). A stream that is gone needs
        /// nothing.
        pub fn answerUnfinishedStream(
            self: *Self,
            active: *RequestSlot,
            response_id: server_responses.Id,
        ) LaneFault!void {
            if (active.ingress_channel_id == 0)
                return;
            const runtime = Admission.requestConnection(self, active) orelse return;
            const stream_id = active.ingress_channel_id;
            switch (runtime.h2StreamState(stream_id) orelse .vacant) {
                .preparing, .active => {},
                .vacant, .draining_response => return,
            }
            if (runtime.responseHeadQueued(stream_id))
                return;
            _ = try Admission.writeH2ServerResponse(self, runtime, stream_id, response_id);
        }

        fn handleReceived(
            self: *Self,
            registration: *completions.Registration,
            received: *Received,
        ) LaneFault!Handled {
            const descriptor = received.descriptor;
            if (descriptor.stream_id == 0)
                return faulted(.descriptor_names_no_request);
            if (descriptor.request_lane_id != self.lane.lane_id) {
                if (descriptor.request_lane_id >= self.service.lanes.len)
                    return faulted(.descriptor_names_no_request);
                return .{ .outcome = try forwardDescriptor(self, registration, received) };
            }
            if (request_done.isRequestDone(descriptor)) {
                const done = switch (request_done.decodeDone(received.payload)) {
                    .done => |done| done,
                    .fault => |reason| return faulted(reason),
                };
                return .{ .outcome = try Done.completeRequest(self, registration.worker_key, descriptor, done) };
            }
            const resolution = try resolveDescriptor(self, registration.worker_key, descriptor);
            const target = switch (resolution) {
                .local => |target| target,
                .stale => {
                    passRingPayload(registration, received.ring_span);
                    return .{};
                },
                .fault => |reason| return faulted(reason),
            };
            const outcome = try queueDescriptor(self, target, received);
            passRingPayload(registration, received.ring_span);
            switch (outcome) {
                .ok => {},
                .would_block, .fault => return .{ .outcome = outcome },
            }
            return .{ .yield = hasBacklog(target.runtime) };
        }

        /// Sends a descriptor of another lane's response to that lane, under
        /// a unit of the worker's window, or its `request_done`
        /// (`forwardRequestDone`). An inline payload moves into the command;
        /// a ring payload stays in the ring, held until the owner answers. A
        /// descriptor whose request the worker's table no longer holds, or
        /// whose `request_done` already went, drops, and one the table holds
        /// under another key is a fault. A lost post, refused or past a full
        /// window, loses the rest of that request's response too
        /// (`forward_loss`).
        fn forwardDescriptor(
            self: *Self,
            registration: *completions.Registration,
            received: *Received,
        ) LaneFault!WorkerOutcome {
            const worker = registration.worker orelse return error.InvalidWorkerRegistration;
            const descriptor = received.descriptor;
            const request_key: lifecycle.RequestKey = .{
                .lane_id = descriptor.request_lane_id,
                .slot = descriptor.request_slot,
                .generation = descriptor.request_generation,
            };
            if (request_done.isRequestDone(descriptor))
                return forwardRequestDone(self, registration, worker, request_key, received);
            if (registration.forward_loss.contains(request_key)) {
                if (endsResponse(descriptor))
                    registration.forward_loss.remove(request_key);
                passRingPayload(registration, received.ring_span);
                self.lane.counters.forwarded_descriptor_drops += 1;
                return .ok;
            }
            switch (worker.requests.forwardCheck(descriptor.request_id, request_key)) {
                .live => {},
                .absent => {
                    passRingPayload(registration, received.ring_span);
                    self.lane.counters.forwarded_descriptor_drops += 1;
                    return .ok;
                },
                .mismatch => return .{ .fault = .descriptor_names_no_request },
            }
            if (!acquireForwardUnit(worker)) {
                passRingPayload(registration, received.ring_span);
                noteForwardLoss(self, registration, request_key, descriptor);
                return .ok;
            }
            var payload: lane_commands.ForwardedPayload = .none;
            if (received.ring_span) |span| {
                // Every payload an honest worker puts in the ring is above
                // the threshold, so fewer than the account holds fit in the
                // ring at once (`SharedPayloadHolds.capacity`).
                if (!registration.ring_payloads.hold(span)) {
                    try releaseForwardUnit(self, worker);
                    return .{ .fault = .payload_ring_invalid };
                }
                payload = .{ .ring = .{ .offset = span.offset, .len = span.len } };
            } else if (received.payload.len != 0) {
                std.debug.assert(received.payload_owned);
                payload = .{ .inline_bytes = .{ .bytes = received.payload, .allocator = received.allocator } };
                received.payload_owned = false;
            }
            // The post consumes the command on every path, so a refused one
            // has already freed its inline copy.
            const posted = try self.postToLane(descriptor.request_lane_id, .{ .forwarded_descriptor = .{
                .request_key = request_key,
                .worker_key = registration.worker_key,
                .worker = worker,
                .reader_lane_id = self.lane.lane_id,
                .descriptor = descriptor,
                .payload = payload,
            } });
            if (posted) {
                self.lane.counters.worker_descriptors_forwarded += 1;
                return .ok;
            }
            try releaseForwardUnit(self, worker);
            if (received.ring_span) |span| {
                if (registration.ring_payloads.answer(span.offset, span.len)) |freed|
                    releaseRingBytes(registration, freed);
            }
            noteForwardLoss(self, registration, request_key, descriptor);
            return .ok;
        }

        /// Sends the `request_done` of another lane's request to that lane,
        /// decoded and outside the forwarding window
        /// (`lane_commands.ForwardedRequestDone` says why it needs no unit).
        /// It is the request's last descriptor, so the reader forgets a loss
        /// it noted for the response, and the owner ends the request with
        /// the response it lost a part of. One whose request the worker's
        /// table no longer holds, or whose `request_done` already went,
        /// drops, and one the table holds under another key is a fault. The
        /// table marks the request's `request_done` forwarded only once the
        /// post took it, so a refused post leaves no claim behind. A refusal
        /// leaves the request to its grace backstop, which faults the worker
        /// although it answered, so it is logged.
        fn forwardRequestDone(
            self: *Self,
            registration: *completions.Registration,
            worker: *WorkerRecord,
            request_key: lifecycle.RequestKey,
            received: *const Received,
        ) LaneFault!WorkerOutcome {
            const descriptor = received.descriptor;
            registration.forward_loss.remove(request_key);
            const done = switch (request_done.decodeDone(received.payload)) {
                .done => |done| done,
                .fault => |reason| return .{ .fault = reason },
            };
            switch (worker.requests.forwardCheck(descriptor.request_id, request_key)) {
                .live => {},
                .absent => {
                    self.lane.counters.forwarded_descriptor_drops += 1;
                    return .ok;
                },
                .mismatch => return .{ .fault = .descriptor_names_no_request },
            }
            const posted = try self.postToLane(descriptor.request_lane_id, .{ .forwarded_request_done = .{
                .request_key = request_key,
                .worker_key = registration.worker_key,
                .worker = worker,
                .descriptor = descriptor,
                .done = done,
            } });
            if (posted) {
                worker.requests.markDoneForwarded(descriptor.request_id, request_key);
                self.lane.counters.worker_descriptors_forwarded += 1;
                return .ok;
            }
            self.lane.counters.forwarded_descriptor_drops += 1;
            std.log.warn(
                "ingress lane {d} could not forward the request_done of worker_id={d} for lane {d}'s request in slot {d}; that request waits for its grace backstop",
                .{
                    self.listener_index,
                    registration.worker_key.worker_id,
                    request_key.lane_id,
                    request_key.slot,
                },
            );
            return .ok;
        }

        /// Counts a forwarded response descriptor that was lost and, unless
        /// it ended its response, drops the rest of that response
        /// (`forward_loss`), whose request's `request_done` then ends it.
        fn noteForwardLoss(
            self: *Self,
            registration: *completions.Registration,
            request_key: lifecycle.RequestKey,
            descriptor: Descriptor,
        ) void {
            self.lane.counters.forwarded_descriptor_drops += 1;
            if (endsResponse(descriptor))
                return;
            registration.forward_loss.add(request_key);
            std.log.warn(
                "ingress lane {d} dropped the rest of a response from worker_id={d}: a forwarded descriptor of lane {d}'s request in slot {d} was lost",
                .{
                    self.listener_index,
                    registration.worker_key.worker_id,
                    request_key.lane_id,
                    request_key.slot,
                },
            );
        }

        /// Matches a descriptor of the worker `worker_key` to a request of
        /// this lane (the header's rule).
        fn resolveDescriptor(
            self: *Self,
            worker_key: lifecycle.WorkerKey,
            descriptor: Descriptor,
        ) LaneFault!Resolution {
            if (descriptor.stream_id == 0)
                return .{ .fault = .descriptor_names_no_request };
            // A later request in the slot carries a later generation, so a
            // key that matches no live request names one that ended.
            const active = switch (self.requests.lookup(descriptor.request_slot, descriptor.request_generation)) {
                .live => |active| active,
                .stale_generation, .vacant => return .stale,
                .out_of_range => return .{ .fault = .descriptor_names_no_request },
            };
            if (!active.dispatched() or !active.worker_key.eql(worker_key))
                return .{ .fault = .descriptor_names_no_request };
            if (active.ingress_channel_id != descriptor.stream_id)
                return .{ .fault = .descriptor_names_no_request };
            if (active.h2_client_reset)
                return .stale;
            const runtime = switch (self.connections.lookup(active.connection_key.slot, active.connection_key.generation)) {
                .live => |runtime| runtime,
                .stale_generation, .vacant, .out_of_range => return .stale,
            };
            if (runtime.state != .http2_connection)
                return error.InvalidH2ConnectionState;
            return .{ .local = .{ .runtime = runtime, .active = active } };
        }

        /// Charges a body chunk to its request's credit window, queues one
        /// worker descriptor onto the request's stream, which takes an owned
        /// payload or copies borrowed ring bytes, and acts on what the HTTP/2
        /// layer decided (`fault.classifyResponseQueueError`). It drives
        /// nothing and finishes no request, so the caller decides what may
        /// run before what.
        fn queueDescriptor(self: *Self, target: Target, received: *Received) LaneFault!WorkerOutcome {
            if (received.descriptor.op == @intFromEnum(Op.response_chunk)) {
                // The writer may retire the chunk before it returns. A failed
                // append ends the response, so this charge needs no rollback.
                if (!target.active.response_credit.trySpend())
                    return .{ .fault = .response_descriptor_invalid };
            }
            if (endsResponse(received.descriptor))
                target.active.response_credit_unsent = false;
            const queued = http2_writing.queueWorkerResponseDescriptor(
                Self,
                self,
                target.runtime,
                received,
            ) catch |err| return actOnQueueError(self, target, received.descriptor, err);
            self.lane.counters.ingress_response_body_bytes += @intCast(queued.body_bytes);
            if (queued.head_status) |status|
                noteHeadQueued(target.active, status);
            return .ok;
        }

        fn actOnQueueError(
            self: *Self,
            target: Target,
            descriptor: Descriptor,
            err: (LaneFault || fault.ResponseQueueError),
        ) LaneFault!WorkerOutcome {
            switch (try fault.classifyResponseQueueError(err)) {
                .worker_fault => |reason| return .{ .fault = reason },
                .connection => |outcome| switch (outcome) {
                    .keep => {
                        // The client is not reading the response as fast as the
                        // worker writes it, or the lane could not hold it.
                        const code: http_common.http2.ErrorCode = if (err == error.Http2PendingResponseTooLarge)
                            .enhance_your_calm
                        else
                            .internal_error;
                        try failStream(self, target, descriptor, code);
                    },
                    .close => |close| Connection.closeRuntimeConnection(self, target.runtime, close),
                },
            }
            return .ok;
        }

        /// Resets a client stream that cannot take its worker's response and
        /// stops the request in the worker, which stays alive; the worker's
        /// `request_done` then ends the request.
        fn failStream(
            self: *Self,
            target: Target,
            descriptor: Descriptor,
            code: http_common.http2.ErrorCode,
        ) LaneFault!void {
            const runtime = target.runtime;
            const request_key = runtime.h2MarkStreamReset(self.service.allocator, descriptor.stream_id) orelse return;
            const active = target.active;
            if (active.isLive() and active.request_key.eql(request_key)) {
                active.h2_client_reset = true;
                try Dispatch.cancelRequestToWorker(
                    self,
                    active.request_key.slot,
                    @intFromEnum(http_common.http2.ErrorCode.cancel),
                );
            }
            try resetClientStream(self, runtime, descriptor.stream_id, code);
        }

        /// Ends the window unit of a forwarded descriptor this lane is done
        /// with: a ring payload's answer to the reader that holds it takes
        /// the unit along, and any other payload releases it here. A refused
        /// answer releases the unit and leaves its ring bytes held for good,
        /// so the worker's later ring payloads wait for room until their
        /// requests' deadlines end them.
        fn endForwardedUnit(self: *Self, forwarded: *const lane_commands.ForwardedDescriptor) LaneFault!void {
            const ring = switch (forwarded.payload) {
                .ring => |ring| ring,
                .none, .inline_bytes => return releaseForwardUnit(self, forwarded.worker),
            };
            const posted = try self.postToLane(forwarded.reader_lane_id, .{ .payload_consumed = .{
                .worker_key = forwarded.worker_key,
                .worker = forwarded.worker,
                .ring = ring,
            } });
            if (posted)
                return;
            try releaseForwardUnit(self, forwarded.worker);
            self.lane.counters.payload_answer_drops += 1;
            std.log.warn(
                "ingress lane {d} could not answer a ring payload of worker_id={d} to lane {d}; its ring bytes stay held",
                .{ self.listener_index, forwarded.worker_key.worker_id, forwarded.reader_lane_id },
            );
        }

        /// The registration through which this lane reads `worker_key`.
        fn readingRegistration(self: *Self, worker_key: lifecycle.WorkerKey) ?*completions.Registration {
            for (self.registrations.touched()) |*registration| {
                if (!registration.inUse() or !registration.reading())
                    continue;
                if (registration.worker_key.eql(worker_key))
                    return registration;
            }
            return null;
        }

        fn resetClientStream(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            code: http_common.http2.ErrorCode,
        ) LaneFault!void {
            // A failed write before this may have closed the connection.
            if (!runtime.isLive() or runtime.state != .http2_connection)
                return;
            if (http2_writing.queueRstStream(Self, self, runtime, stream_id, code)) |_| {} else |err| {
                switch (try fault.classifyConnectionError(.{ .http2 = err })) {
                    .keep => {},
                    .close => |close| Connection.closeRuntimeConnection(self, runtime, close),
                }
            }
        }
    };
}

fn faulted(reason: WorkerFaultReason) Handled {
    return .{ .outcome = .{ .fault = reason } };
}

/// Accounts for a ring payload that is done with, freeing the ring bytes the
/// reader's account allows (`SharedPayloadHolds.pass`).
fn passRingPayload(registration: *completions.Registration, span: ?ipc.ingress_channel.SharedPayloadSpan) void {
    const ring_span = span orelse return;
    releaseRingBytes(registration, registration.ring_payloads.pass(ring_span));
}

/// Frees `byte_len` bytes at the read cursor of the worker's ring, which
/// signals the worker's credit eventfd when it marked itself waiting for
/// room (`SharedPayloadReadRelease`).
fn releaseRingBytes(registration: *completions.Registration, byte_len: u64) void {
    if (byte_len == 0)
        return;
    var release: ipc.ingress_channel.SharedPayloadReadRelease = .{
        .view = registration.ingress_payload,
        .direction = .worker_to_server,
        .byte_len = byte_len,
        .credit_eventfd = registration.ingress_payload_credit_eventfd,
    };
    release.release();
}

/// The bytes of a ring payload another lane's reader holds for this lane's
/// request, read through the worker record the request holds. Null when they
/// fall outside the ring, which the reader's checks rule out, so the payload
/// cannot be trusted.
fn heldRingPayload(active: *RequestSlot, ring: lane_commands.RingRef) ?[]u8 {
    const worker = active.worker orelse return null;
    return worker.handle.ingress_payload.heldPayload(.worker_to_server, ring.offset, ring.len) catch |err| switch (err) {
        error.InvalidIngressSharedPayloadRing => null,
    };
}

/// Records on the request's access facts that the worker's response head
/// with `status` went toward the client: the status the client receives,
/// which its access record carries whatever the worker reports later
/// (`request_finish.zig`), and the time to first byte, an earlier stamp
/// kept.
fn noteHeadQueued(active: *RequestSlot, status: u16) void {
    active.access.response_status = status;
    if (active.access.first_byte_mono_ns == 0)
        active.access.first_byte_mono_ns = process.monotonicNowNsOrZero();
}

/// Whether no descriptor of the response follows `descriptor`: the
/// response's end or reset, or a descriptor that carries END_STREAM.
fn endsResponse(descriptor: Descriptor) bool {
    if (descriptor.op == @intFromEnum(Op.response_end) or descriptor.op == @intFromEnum(Op.response_reset))
        return true;
    return descriptor.hasFlag(ipc.ingress_channel.flags.end_stream);
}

/// Whether an open connection cannot take more of a worker's response now:
/// its socket refuses queued writes, or its send windows hold response bytes
/// or an END_STREAM back. Bytes queued for the connection's next flush are no
/// backlog, since the pass writes them (`http2/writing.zig`).
fn hasBacklog(runtime: *const ConnectionSlot) bool {
    if (!runtime.isOpen())
        return false;
    if (runtime.h2WritesBlocked())
        return true;
    if (runtime.h2_pending_response_bytes != 0)
        return true;
    var stream_index: usize = 0;
    return runtime.h2PendingResponseStreamId(&stream_index) != null;
}
