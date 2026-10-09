//! A worker's fs-fault socket, read on the ingress lane thread that is the
//! worker's reader (`server/supervisor/pool.zig`). The fault SEQPACKET pair
//! has its own descriptor (`Registration.fs_fault_fd`, from
//! `WorkerHandle.fs_fault_fd`), so a fault never consumes a control packet and
//! a control packet never consumes a fault.
//!
//! Every well-formed fault gets one answer, at once, and no answer carries a
//! descriptor:
//! - Identity fails closed. Only a request of this worker that this lane has
//!   in flight, with the fault's request id and generation, is served. A
//!   request another lane owns is refused, since the reader holds no record
//!   of it, and so is the request-less boot permit 0/0, since a lane reads a
//!   worker only after it is ready.
//! - An authorized fault answers `.not_found`: every route artifact borrows
//!   the same empty placeholder index (`server/routes/artifacts.zig`), so no
//!   path is indexed.
//!
//! A malformed fault, one that carries a descriptor, and every receive error
//! are the worker's fault (`fault.classifyWorkerError`), which the drain
//! returns for the caller to act on. An answer that would block is dropped
//! and counted, and the worker's read then ends at its request's deadline
//! (`worker/fs/fault.zig`), which is why nothing here queues or waits.

const std = @import("std");

const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");

const completions = @import("../completions.zig");
const fault = @import("../fault.zig");

const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;

/// Faults one drain answers before it gives the loop back, so a worker that
/// keeps faulting shares the lane with everything else on it.
pub const fault_packets_per_drain_max: usize = 64;

pub fn Methods(comptime Self: type) type {
    return struct {
        /// Answers the faults waiting on the fault socket of the worker that
        /// the registration at `registration_index` reads, up to a bounded
        /// batch. Returns `.would_block` once the socket is empty, `.ok` when
        /// the batch ended with faults possibly left, and `.fault` when the
        /// worker broke the channel's protocol; the caller then runs the death
        /// path. Fails only with the lane's own faults, a registration that
        /// does not read its worker among them.
        pub fn drainWorkerFsFault(self: *Self, registration_index: u32) LaneFault!WorkerOutcome {
            const registration = try readerRegistration(self, registration_index);
            var drained_packets: usize = 0;
            while (drained_packets < fault_packets_per_drain_max) : (drained_packets += 1) {
                var packet = ipc.recvPacketWithFdsScratch(
                    self.service.allocator,
                    registration.fs_fault_fd,
                    self.ipc_recv_scratch,
                ) catch |err| return fault.classifyWorkerError(.{ .receive = err });
                defer packet.deinit();
                if (packet.fd_count != 0)
                    return .{ .fault = .unexpected_descriptor };
                var request = ipc.fs_fault.decodeRequest(self.service.allocator, packet.bytes) catch |err|
                    return fault.classifyWorkerError(.{ .fs_fault_decode = err });
                defer request.deinit();
                const outcome = try sendAnswer(self, registration, request.fault_id, answerFor(self, registration, &request));
                switch (outcome) {
                    .ok => {},
                    .would_block, .fault => return outcome,
                }
            }
            return .ok;
        }

        fn answerFor(
            self: *Self,
            registration: *const completions.Registration,
            request: *const ipc.FsFaultRequest,
        ) ipc.FsFaultResponseStatus {
            const worker_key: lifecycle.WorkerKey = .{
                .worker_id = request.worker_id,
                .worker_generation = request.worker_generation,
            };
            if (!registration.worker_key.eql(worker_key))
                return .refused;
            if (request.request_id == 0)
                return .refused;
            if (!servesRequest(self, registration, request))
                return .refused;
            return .not_found;
        }

        /// Whether a request of this lane in flight on the worker carries the
        /// fault's request id and generation. Scans the registration's list,
        /// at most `completions.max_worker_inflight_requests` keys.
        fn servesRequest(
            self: *Self,
            registration: *const completions.Registration,
            request: *const ipc.FsFaultRequest,
        ) bool {
            for (registration.inflight_request_keys[0..registration.inflight_request_len]) |key| {
                const active = switch (self.requests.lookup(key.slot, key.generation)) {
                    .live => |active| active,
                    .stale_generation, .vacant, .out_of_range => continue,
                };
                if (!active.worker_key.eql(registration.worker_key))
                    continue;
                if (active.request_id != request.request_id)
                    continue;
                if (key.generation != request.request_generation)
                    continue;
                return true;
            }
            return false;
        }

        /// Sends a failure answer, which carries no descriptor. An answer that
        /// would block is dropped and counted.
        fn sendAnswer(
            self: *Self,
            registration: *completions.Registration,
            fault_id: u64,
            status: ipc.FsFaultResponseStatus,
        ) LaneFault!WorkerOutcome {
            std.debug.assert(status != .ok);
            ipc.fs_fault.sendResponse(
                registration.fs_fault_fd,
                .{ .fault_id = fault_id, .status = status },
                null,
            ) catch |err| switch (try fault.classifyWorkerError(.{ .send = err })) {
                .ok => {},
                .would_block => self.lane.counters.fs_fault_answer_drops += 1,
                .fault => |reason| return .{ .fault = reason },
            };
            return .ok;
        }

        /// The registration at `registration_index`, which must read its
        /// worker: only the reader may read a worker's fault socket, and only
        /// its polls call the drain.
        fn readerRegistration(self: *Self, registration_index: u32) LaneFault!*completions.Registration {
            const registration = self.registrations.get(registration_index) orelse
                return error.InvalidCompletionRegistration;
            if (!registration.reading() or registration.fs_fault_fd < 0)
                return error.InvalidCompletionRegistration;
            return registration;
        }
    };
}
