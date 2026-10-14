//! The ingress side of one worker request, played inside a bench process on
//! the caller's thread. It hands a DispatchWork to an in-process worker
//! runtime as one request-begin descriptor with inline bytes, and reads the
//! response back as every host does (`host.dispatch.readResponse`), up to
//! the request's `request_done` on the control socket, granting the worker
//! response credit for each chunk it takes. The read runs one pass of the
//! runtime before each look at the socket (`worker.runPass`), so the request
//! runs to its end inside the read, and a response longer than its credit
//! window finishes as it would under a server.
//!
//! The runtime must be built as a real worker's is: the worker's end of the
//! control socket does not block, and a payload ring is mapped for bodies
//! above `ipc.ingress_channel.shared_payload_threshold`. The reader takes
//! ring payloads through the host's own mapping of that ring
//! (`ipc.ingress_channel.mapSharedPayloadReadWrite` with `.server`), since
//! the worker's mapping writes the direction the host reads.

const std = @import("std");
const host = @import("collo_host");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");

/// Byte caps of a read, far above the JSON a bench answers with, so they
/// only stop a runaway worker.
const read_max_body_bytes: usize = 16 * 1024 * 1024;
const read_max_headers_bytes: usize = 64 * 1024;

/// Hands `dispatch` to the in-process `runtime` as one request-begin
/// descriptor with a copy of its encoded bytes inline. The runtime must have
/// registered the route `dispatch` names. The caller keeps `dispatch`; the
/// runtime owns the copy from the call on, failure included.
pub fn enqueueRoute(
    allocator: std.mem.Allocator,
    runtime: *worker.Runtime,
    dispatch: *ipc.DispatchWork,
    stream_id: u32,
) !void {
    var payload_scratch: [ipc.max_message_bytes]u8 = undefined;
    var view = dispatch.view();
    const payload = try ipc.encodeDispatchWorkInto(&payload_scratch, &view);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = dispatch.request_id,
        .request_generation = dispatch.request_generation,
        .request_lane_id = dispatch.request_lane_id,
        .request_slot = dispatch.request_slot,
    };
    var descriptor = ipc.ingress_channel.Descriptor.requestBegin(
        identity,
        stream_id,
        0,
        @intCast(payload.len),
        @intCast(dispatch.request_headers.len),
        true,
    );
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;

    try runtime.enqueueIngressDescriptor(.{
        .allocator = allocator,
        .descriptor = descriptor,
        .payload = try allocator.dupe(u8, payload),
    });
}

/// The host's ends of an in-process worker's transport.
pub const HostEnds = struct {
    /// The host's end of the worker's control socket.
    control_fd: std.posix.fd_t,
    /// The host's mapping of the worker's payload ring.
    ingress_payload: *ipc.ingress_channel.SharedPayloadView,
};

/// Reads the response of `request_id` from `runtime` through `ends`,
/// running the runtime until the request finishes or `wall_ms` passes. The
/// caller owns the returned Response and frees it with `deinit`. Fails as
/// `host.dispatch.readResponse` does, and with the error of a pass of the
/// runtime.
pub fn readResponse(
    allocator: std.mem.Allocator,
    runtime: *worker.Runtime,
    ends: HostEnds,
    request_id: u64,
    wall_ms: u32,
) !host.dispatch.Response {
    const channels: host.dispatch.ResponseChannels = .{
        .control_fd = ends.control_fd,
        .ingress_payload = ends.ingress_payload,
    };
    return host.dispatch.readResponse(allocator, channels, request_id, .{
        .wall_ms = wall_ms,
        .max_body_bytes = read_max_body_bytes,
        .max_headers_bytes = read_max_headers_bytes,
        .progress_context = runtime,
        .progress_fn = runPass,
    });
}

fn runPass(context: ?*anyopaque) !void {
    const runtime: *worker.Runtime = @ptrCast(@alignCast(context.?));
    try worker.runPass(runtime);
}
