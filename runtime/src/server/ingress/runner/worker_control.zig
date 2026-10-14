//! A worker's control socket, read on the ingress lane thread that is the
//! worker's reader (`server/supervisor/pool.zig`). A worker sends two kinds
//! of packet on it: ingress descriptors, a request's `request_done` among
//! them, and once at most the notice that it asks to be retired
//! (`ipc.worker_retiring`). The drain decodes each descriptor packet with
//! the reader's account of the worker's ring (`Registration.ring_payloads`),
//! so a ring payload decodes from the end of the last one even while earlier
//! ones wait for another lane, and hands the descriptors to
//! `h2_worker_ipc.zig`, which applies those of this lane's requests in the
//! order the worker sent them and forwards the rest. The loop's drains
//! receive a packet only while the worker's forwarding window has room for
//! its descriptors (`h2_worker_ipc.windowHasRoom`); a full window stops them
//! until the release that makes room wakes the lane
//! (`resumeWindowBlockedReaders`).
//!
//! A retiring notice takes the worker out of service with no death: the
//! pool stops handing its slots out, the requests it holds finish on it, and
//! the reaper retires it once no lane holds a slot of it or reads it
//! (`Pool.retireOnNotice`). The notice comes after every descriptor the
//! worker sent before it, and the drain goes on past it, since the worker
//! keeps answering what it holds.
//!
//! Every receive and decode error, and every packet the channel never
//! carries, is the worker's fault (`fault.classifyWorkerError`), which the
//! drain returns for the caller to act on; only the lane's own errors
//! (`fault.LaneFault`) leave it as errors.

const std = @import("std");
const ipc = @import("collo_ipc");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const admission = @import("admission.zig");
const h2_worker_ipc = @import("h2_worker_ipc.zig");
const worker_fault = @import("worker_fault.zig");
const worker_registration = @import("worker_registration.zig");

const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;
const Handled = h2_worker_ipc.Handled;

/// Packets one drain reads before it gives the loop back, so a worker that
/// keeps its socket full shares the lane with everything else on it.
pub const control_packets_per_drain_max: usize = 64;

/// Whether a drain stops at a connection that has bytes to write before more
/// of a worker's response, and at a full forwarding window. The loop's
/// drains stop there and let the loop write the bytes first, or wait for
/// the window. A drain that must take the worker's output now, the last read
/// of a dead worker or the grace backstop, reads on: the connection's
/// pending-response bound still caps what it buffers, a response descriptor
/// that finds the window full drops, and a `request_done`, which takes no
/// unit of the window, still goes on (`h2_worker_ipc.zig`).
pub const Pace = enum {
    yield_to_backlog,
    read_through,
};

pub fn Methods(comptime Self: type) type {
    return struct {
        const Admission = admission.Methods(Self);
        const WorkerFault = worker_fault.Methods(Self);
        const WorkerIpc = h2_worker_ipc.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// The reader's read of the worker of registration
        /// `registration_index` when its control socket's poll fires: a
        /// bounded drain that yields to the connections it gave bytes to,
        /// then the worker's polls armed again, or the death path on a
        /// fault.
        pub fn readWorkerControl(self: *Self, registration_index: u32) LaneFault!void {
            switch (try drainWorkerControl(self, registration_index, .yield_to_backlog)) {
                .ok, .would_block => try WorkerRegistration.armWorkerPolls(self, registration_index),
                .fault => |reason| try WorkerFault.faultWorker(self, registration_index, reason),
            }
        }

        /// Handles this lane's `window_reopened` wake: every registration
        /// whose worker's forwarding window was full and has room again
        /// reads the worker's control socket as its poll would. One whose
        /// window is still full stays blocked, with its mark as the window's
        /// waiter set again (`h2_worker_ipc.windowHasRoom`).
        pub fn resumeWindowBlockedReaders(self: *Self) LaneFault!void {
            for (self.registrations.touched(), 0..) |*registration, index| {
                if (!registration.inUse() or !registration.reading() or !registration.window_blocked)
                    continue;
                const worker = registration.worker orelse return error.InvalidWorkerRegistration;
                if (!h2_worker_ipc.windowHasRoom(worker, self.lane.lane_id))
                    continue;
                registration.window_blocked = false;
                try readWorkerControl(self, @intCast(index));
            }
        }

        /// Reads the control socket of the worker that the registration at
        /// `registration_index` reads, until the socket is empty, a bounded
        /// batch was read, or, with `.yield_to_backlog`, a connection the
        /// responses went to has bytes to write first or the worker's
        /// forwarding window has no room for another packet. Returns
        /// `.would_block` once the socket is empty; `.ok` when the drain
        /// stopped early with packets possibly left, which a re-armed read
        /// poll finds at once, or, with `window_blocked` set on the
        /// registration, once the window reopens; `.fault` when the worker
        /// broke the channel's protocol, and the caller runs the death path.
        /// Fails only with the lane's own faults, a registration that does
        /// not read its worker among them.
        pub fn drainWorkerControl(self: *Self, registration_index: u32, pace: Pace) LaneFault!WorkerOutcome {
            const registration = try readerRegistration(self, registration_index);
            var drained_packets: usize = 0;
            while (drained_packets < control_packets_per_drain_max) : (drained_packets += 1) {
                switch (pace) {
                    .yield_to_backlog => if (!try windowAllowsPacket(self, registration)) return .ok,
                    .read_through => {},
                }
                var packet = ipc.recvPacketWithFdsScratch(
                    self.service.allocator,
                    registration.control_fd,
                    self.ipc_recv_scratch,
                ) catch |err| return fault.classifyWorkerError(.{ .receive = err });
                const handled = try handlePacket(self, registration, &packet);
                switch (handled.outcome) {
                    .ok => {},
                    .would_block, .fault => return handled.outcome,
                }
                switch (pace) {
                    .yield_to_backlog => if (handled.yield) return .ok,
                    .read_through => {},
                }
            }
            return .ok;
        }

        /// Decodes one packet and hands its descriptors on. Consumes `packet`
        /// on every path.
        fn handlePacket(
            self: *Self,
            registration: *completions.Registration,
            packet: *ipc.packet.ReceivedPacket,
        ) LaneFault!Handled {
            // No packet from a worker carries descriptors, and freeing the
            // packet closes any it brought.
            if (packet.fd_count != 0) {
                packet.deinit();
                return faulted(.unexpected_descriptor);
            }
            if (packet.bytes.len < @sizeOf(u32)) {
                packet.deinit();
                return faulted(.packet_short);
            }
            const raw_kind = ipc.packet.readStruct(u32, packet.bytes[0..@sizeOf(u32)]);
            const kind = ipc.decodeMessageKind(raw_kind) catch |err| {
                packet.deinit();
                return .{ .outcome = try fault.classifyWorkerError(.{ .ingress_decode = err }) };
            };
            if (kind == .worker_retiring) {
                defer packet.deinit();
                const reason = ipc.worker_retiring.decode(packet) catch |err|
                    return .{ .outcome = try fault.classifyWorkerError(.{ .retiring_decode = err }) };
                try retireOnNotice(self, registration, reason);
                return .{ .outcome = .ok };
            }
            if (kind != .ingress_channel) {
                packet.deinit();
                return faulted(.unknown_kind);
            }
            const readers: ipc.ingress_channel.SharedPayloadReaders = .{
                .worker_to_server = registration.ingress_payload,
                .worker_to_server_credit_eventfd = registration.ingress_payload_credit_eventfd,
                .worker_to_server_holds = &registration.ring_payloads,
            };
            if (ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
                var batch = ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload(
                    self.service.allocator,
                    packet,
                    readers,
                ) catch |err| return .{ .outcome = try fault.classifyWorkerError(.{ .ingress_decode = err }) };
                defer batch.deinit();
                return WorkerIpc.handleWorkerBatch(self, registration, &batch);
            }
            var received = ipc.ingress_channel.decodeReceivedPacketWithSharedPayload(
                self.service.allocator,
                packet,
                readers,
            ) catch |err| return .{ .outcome = try fault.classifyWorkerError(.{ .ingress_decode = err }) };
            defer received.deinit();
            return WorkerIpc.handleWorkerDescriptor(self, registration, &received);
        }

        /// Acts on the worker's notice that it asks to be retired for
        /// `reason`: its pool takes it out of service without a death
        /// (`Pool.retireOnNotice`), and the lanes that hold its slots finish
        /// their requests on it. When nothing holds a slot any more, the
        /// worker's reader, this lane, gives its role up through its own
        /// queue (`release_worker`), after the drain that read the notice,
        /// and the reaper retires the worker. The definition's waiters get a
        /// replacement launch or 503 (`Admission.growOrStrand`).
        fn retireOnNotice(
            self: *Self,
            registration: *completions.Registration,
            reason: ipc.WorkerRetiringReason,
        ) LaneFault!void {
            const worker = registration.worker orelse return error.InvalidWorkerRegistration;
            const definition = worker.definition_index;
            self.lane.counters.retirement_notices += 1;
            std.log.info("worker asks to be retired worker_id={d} reason={s}", .{ worker.id, @tagName(reason) });
            switch (self.service.supervisor.poolFor(definition).retireOnNotice(worker, registration.worker_key)) {
                // A notice after the worker left service, or a repeat, which
                // an honest worker never sends.
                .stale => return,
                .draining => {},
                .retire => self.service.queueRetirement(worker),
                .release_reader => |tenure| {
                    // A refused post leaves the release to the reaper's retry
                    // (`Reaper.retryReleases`).
                    if (!try self.postToLane(tenure.lane, .{ .release_worker = .{
                        .worker_key = registration.worker_key,
                        .epoch = tenure.epoch,
                    } }))
                        self.lane.counters.release_worker_refusals += 1;
                },
            }
            try Admission.growOrStrand(self, definition, .replacement);
        }

        /// Whether the reader may receive the worker's next packet: its
        /// forwarding window has room for every descriptor a packet carries.
        /// A window without room blocks the registration, whose polls on the
        /// control socket then wait for the window to reopen
        /// (`worker_registration.armWorkerPolls`).
        fn windowAllowsPacket(self: *Self, registration: *completions.Registration) LaneFault!bool {
            if (registration.window_blocked)
                return false;
            const worker = registration.worker orelse return error.InvalidWorkerRegistration;
            if (h2_worker_ipc.windowHasRoom(worker, self.lane.lane_id))
                return true;
            registration.window_blocked = true;
            self.lane.counters.forward_window_waits += 1;
            return false;
        }

        /// The registration at `registration_index`, which must read its
        /// worker: only the reader may read a worker's control socket, and
        /// only its polls call the drain.
        fn readerRegistration(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            const registration = self.registrations.get(registration_index) orelse
                return error.InvalidWorkerRegistration;
            if (!registration.reading() or registration.control_fd < 0)
                return error.InvalidWorkerRegistration;
            return registration;
        }
    };
}

fn faulted(reason: fault.WorkerFaultReason) Handled {
    return .{ .outcome = .{ .fault = reason } };
}
