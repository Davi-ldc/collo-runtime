//! A worker's `request_done`, on the ingress lane thread that owns the
//! request it names. The worker sends it on its control socket as the last
//! descriptor of a request (`common/ipc/ingress_channel/framing.zig`), so
//! everything the worker sent for the request is ahead of it in the socket,
//! and ahead of it in the owner's queue when the reader forwards both. The
//! reader decodes it (`decodeRequestDone`, which refuses a payload that is
//! not exactly one `RequestDonePayload` with known values) and hands one of
//! its own lane's requests here from its drain
//! (`h2_worker_ipc.handleReceived`); one of another lane's request travels
//! decoded as a `forwarded_request_done` and reaches here on the owner
//! (`command_flow.applyForwardedRequestDone`).
//!
//! - A `request_done` is worker output, and its values are the worker's
//!   claim. It acts only on the request it names exactly: a live request of
//!   this lane at its key, dispatched to the sending worker under the same
//!   request id and stream, whose begin reached the worker. One whose
//!   request ended, or whose slot holds a later request, drops as stale,
//!   counted; any other mismatch is a worker fault returned to the caller,
//!   which runs the death path.
//! - It finishes the request at once with the worker's measures
//!   (`request_finish.zig`), whatever the client's stream holds: a response
//!   whose end the lane queued still drains to the client, and one whose end
//!   never came is reset, since nothing of the worker's can follow. Its
//!   status reaches the access record only when no response head of the
//!   worker went out (`request_finish.workerDoneStatus`).
//! - The slot keeps nothing of it, and anything the worker sends for the
//!   request afterwards finds the request gone and drops as stale.

const std = @import("std");
const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");
const fault = @import("../fault.zig");
const request_finish = @import("request_finish.zig");

const LaneFault = fault.LaneFault;
const WorkerOutcome = fault.WorkerOutcome;
const Descriptor = ipc.ingress_channel.Descriptor;
const RequestDone = ipc.ingress_channel.RequestDone;

/// Whether `descriptor` is a request's `request_done`.
pub fn isRequestDone(descriptor: Descriptor) bool {
    return descriptor.op == @intFromEnum(ipc.ingress_channel.Op.request_done);
}

/// What the reader made of a `request_done`'s payload (`decodeDone`).
pub const Decoded = union(enum) {
    done: RequestDone,
    fault: fault.WorkerFaultReason,
};

/// The record a `request_done` carries in `payload`, its descriptor's
/// payload as the reader received it, or the worker fault a payload the
/// decoder refuses is. The reader's packet decoder already refused such a
/// payload (`common/ipc/ingress_channel/receive.zig`), so the fault is a
/// second line, never a path an honest worker reaches.
pub fn decodeDone(payload: []const u8) Decoded {
    const done = ipc.ingress_channel.decodeRequestDone(payload) catch |err| switch (err) {
        error.InvalidPacket => return .{ .fault = .ingress_channel_undecodable },
    };
    return .{ .done = done };
}

pub fn Methods(comptime Self: type) type {
    return struct {
        const RequestFinish = request_finish.Methods(Self);

        /// What a `request_done` names on this lane.
        const Resolution = union(enum) {
            /// The slot of the request it finishes.
            live: u32,
            /// The request ended, or its slot holds a later request.
            stale,
            fault: fault.WorkerFaultReason,
        };

        /// Finishes the request of this lane that a `request_done` of the
        /// worker `worker_key` names (the file header's rule), with `done`
        /// the record the reader decoded from it. Returns `.fault` when the
        /// descriptor shows the worker faulty; the caller runs the death
        /// path for `worker_key`.
        pub fn completeRequest(
            self: *Self,
            worker_key: lifecycle.WorkerKey,
            descriptor: Descriptor,
            done: RequestDone,
        ) LaneFault!WorkerOutcome {
            std.debug.assert(isRequestDone(descriptor));
            std.debug.assert(descriptor.request_lane_id == self.lane.lane_id);
            const request_slot = switch (resolve(self, worker_key, descriptor)) {
                .live => |request_slot| request_slot,
                .stale => {
                    self.lane.counters.stale_request_done += 1;
                    return .ok;
                },
                .fault => |reason| return .{ .fault = reason },
            };
            try RequestFinish.finishRequest(self, request_slot, .{ .worker_done = done });
            return .ok;
        }

        /// Matches a `request_done` of the worker `worker_key` to a request
        /// of this lane. A later request in the slot carries a later
        /// generation, so a key that matches no live request names one that
        /// ended.
        fn resolve(self: *Self, worker_key: lifecycle.WorkerKey, descriptor: Descriptor) Resolution {
            const active = switch (self.requests.lookup(descriptor.request_slot, descriptor.request_generation)) {
                .live => |active| active,
                .stale_generation, .vacant => return .stale,
                .out_of_range => return .{ .fault = .descriptor_names_no_request },
            };
            if (!active.dispatched() or !active.worker_key.eql(worker_key))
                return .{ .fault = .descriptor_names_no_request };
            if (active.request_id != descriptor.request_id)
                return .{ .fault = .descriptor_names_no_request };
            if (active.ingress_channel_id != descriptor.stream_id)
                return .{ .fault = .descriptor_names_no_request };
            // A worker learns of a request only from its begin.
            if (!active.begin_sent)
                return .{ .fault = .descriptor_names_no_request };
            return .{ .live = descriptor.request_slot };
        }
    };
}
