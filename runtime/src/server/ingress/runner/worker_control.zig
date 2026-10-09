//! A worker's control socket, read on the ingress lane thread that is the
//! worker's reader (`server/supervisor/pool.zig`). A worker sends only
//! ingress descriptors on it. The drain decodes each packet with the reader's
//! account of the worker's ring (`Registration.ring_payloads`), so a ring
//! payload decodes from the end of the last one even while earlier ones wait
//! for another lane, and hands the descriptors to `h2_worker_ipc.zig`, which
//! queues those of this lane's requests and forwards the rest.
//!
//! Every receive and decode error, and every packet the channel never
//! carries, is the worker's fault (`fault.classifyWorkerError`), which the
//! drain returns for the caller to act on; only the lane's own errors
//! (`fault.LaneFault`) leave it as errors.

const ipc = @import("collo_ipc");
const completions = @import("../completions.zig");
const fault = @import("../fault.zig");
const h2_worker_ipc = @import("h2_worker_ipc.zig");

const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;
const Handled = h2_worker_ipc.Handled;

/// Packets one drain reads before it gives the loop back, so a worker that
/// keeps its socket full shares the lane with everything else on it.
pub const control_packets_per_drain_max: usize = 64;

/// Whether a drain stops at a connection that has bytes to write before more
/// of a worker's response. The loop's drains stop there and let the loop
/// write them first. A drain that must take the worker's output now, the
/// last read of a dead worker or the grace backstop, reads on, and the
/// connection's pending-response bound still caps what it buffers.
pub const Pace = enum {
    yield_to_backlog,
    read_through,
};

pub fn Methods(comptime Self: type) type {
    return struct {
        const WorkerIpc = h2_worker_ipc.Methods(Self);

        /// Reads the control socket of the worker that the registration at
        /// `registration_index` reads, until the socket is empty, a bounded
        /// batch was read, or, with `.yield_to_backlog`, a connection the
        /// responses went to has bytes to write first. Returns `.would_block`
        /// once the socket is empty; `.ok` when the drain stopped early with
        /// packets possibly left, which a re-armed read poll finds at once;
        /// `.fault` when the worker broke the channel's protocol, and the
        /// caller runs the death path. Fails only with the lane's own faults,
        /// a registration that does not read its worker among them.
        pub fn drainWorkerControl(self: *Self, registration_index: u32, pace: Pace) LaneFault!WorkerOutcome {
            const registration = try readerRegistration(self, registration_index);
            var drained_packets: usize = 0;
            while (drained_packets < control_packets_per_drain_max) : (drained_packets += 1) {
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

        /// The registration at `registration_index`, which must read its
        /// worker: only the reader may read a worker's control socket, and
        /// only its polls call the drain.
        fn readerRegistration(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            if (registration_index >= self.completion_registration_count)
                return error.InvalidCompletionRegistration;
            const registration = &self.completion_registrations[registration_index];
            if (!registration.inUse() or !registration.reading() or registration.control_fd < 0)
                return error.InvalidCompletionRegistration;
            return registration;
        }
    };
}

fn faulted(reason: fault.WorkerFaultReason) Handled {
    return .{ .outcome = .{ .fault = reason } };
}
