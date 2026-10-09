//! Checks a request-begin descriptor from the ingress channel against the
//! `DispatchWork` decoded from the same packet, before the worker builds a
//! request from it (`request/ingress/runtime.zig`). Runs on the worker's VM
//! thread. The identity checked here, assigned by the host, is the one every
//! later packet of the request must repeat.

const ipc = @import("collo_ipc");

/// Fails with `error.InvalidH2WorkerInboundDescriptor` for a descriptor that
/// is not a request begin with its payload inline, with
/// `error.InvalidH2StreamIdentity` when its stream id or request identity is
/// unusable or differs from the dispatch's, and with
/// `error.InvalidH2DispatchRequestHead` when its header count differs from
/// the dispatch's header list.
pub fn validateStreamBeginDescriptor(
    descriptor: ipc.ingress_channel.Descriptor,
    dispatch_work: *const ipc.DispatchWork,
) !void {
    if (descriptor.op != @intFromEnum(ipc.ingress_channel.Op.request_begin))
        return error.InvalidH2WorkerInboundDescriptor;
    if (!descriptor.hasFlag(ipc.ingress_channel.flags.inline_bytes) or descriptor.hasFlag(ipc.ingress_channel.flags.shared_ring))
        return error.InvalidH2WorkerInboundDescriptor;
    // The descriptor carries the client's stream id, and a client opens only
    // odd-numbered streams (RFC 9113 §5.1.1).
    if (descriptor.stream_id == 0 or descriptor.stream_id % 2 == 0)
        return error.InvalidH2StreamIdentity;
    // The request runs under the host's id and generation, so both must be
    // assigned: 0 means no request, and generation 0 marks the boot context
    // (`RequestContext.request_generation`).
    if (dispatch_work.request_id == 0 or dispatch_work.request_generation == 0)
        return error.InvalidH2StreamIdentity;
    if (descriptor.request_id != dispatch_work.request_id or
        descriptor.request_generation != dispatch_work.request_generation or
        descriptor.request_lane_id != dispatch_work.request_lane_id or
        descriptor.request_slot != dispatch_work.request_slot)
    {
        return error.InvalidH2StreamIdentity;
    }
    // A request begin's `aux` is its header count (`Descriptor.requestBegin`).
    if (descriptor.aux != dispatch_work.request_headers.len)
        return error.InvalidH2DispatchRequestHead;
}
