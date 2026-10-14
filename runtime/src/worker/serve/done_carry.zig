//! The `request_done` a finishing request's last packet carries
//! (`common/ipc/ingress_channel/framing.zig:RequestDone`), built once the
//! rest of that packet is composed (`response_payload_writer.zig:Ending`).
//! Its CPU therefore holds every owner window of the request up to the
//! packet's composition, its cleanup's JavaScript included, and only the
//! packet's send and the context's teardown fall outside it. It runs on the
//! worker's VM thread, inside the request's owner window that
//! `response_finish.zig:finishRequest` holds open.

const ipc = @import("collo_ipc");
const request_context = @import("collo_worker_request").context;
const runtime_owner = @import("../runtime/owner.zig");
const state = @import("../runtime/root.zig");

pub const DoneCarry = struct {
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
    /// Built by the first `take`, or the record a parked last packet kept
    /// (`RequestContext.last_packet_done`).
    done: ?ipc.ingress_channel.RequestDone = null,

    /// The request's `request_done`. The first call folds the open window
    /// into the request's CPU (`owner.foldOpenWindow`), which also stores it
    /// in the request's live slot, and counts the `body_bytes` the packet
    /// carries among the bytes served, since that packet takes them to the
    /// server. Later calls, the retries of a packet that found no room,
    /// return the same record, since those bytes did not change.
    pub fn take(
        self: *DoneCarry,
        runtime: *state.Runtime,
        request_ctx: *request_context.RequestContext,
        body_bytes: usize,
    ) ipc.ingress_channel.RequestDone {
        if (self.done) |done| return done;
        runtime_owner.foldOpenWindow(runtime, request_ctx);
        const done = requestDone(request_ctx, self.done_status, self.http_status, body_bytes);
        self.done = done;
        return done;
    }
};

/// The measures of the request's `request_done`. The timeline is sealed and
/// the open window folded, so each is final.
fn requestDone(
    request_ctx: *const request_context.RequestContext,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
    body_bytes: usize,
) ipc.ingress_channel.RequestDone {
    return .{
        .status = done_status,
        .http_status = http_status,
        // The worker's partition of its own span of the request; the server
        // takes the wall time from its own clock.
        .exec_ns = request_ctx.execNs(),
        .waiting_ns = request_ctx.waiting_ns,
        .io_ns = request_ctx.io_time_ns,
        .cpu_ns = request_ctx.cpu_ns,
        .client_served_bytes = request_ctx.client_served_bytes +| body_bytes,
        .fetch_sent_bytes = request_ctx.fetch_sent_bytes,
        .fetch_received_bytes = request_ctx.fetch_received_bytes,
    };
}
