//! Feeds gateway body-pool extents to fetch bodies, on the worker's VM
//! thread. An extent is read in place from the shared pool. Its release,
//! which queues it back for the gateway to reuse, is the worker's
//! flow-control acknowledgment, so it fires exactly once, after the last
//! reader is done with the bytes.

const ipc = @import("collo_ipc");
const Runtime = @import("../../runtime/root.zig").Runtime;
const gateway_control = @import("../gateway_control.zig");
const body_mod = @import("body.zig");

const Body = body_mod.Body;

/// Appends the extent `chunk` names to `body` as a borrowed chunk; the body
/// owns the extent on success. A failed append releases the extent before
/// the error returns, and a failed borrow took nothing, so the caller never
/// releases it.
pub fn appendGatewayBodyPoolChunk(runtime: *Runtime, body: *Body, chunk: ipc.EgressBodyChunkView) !void {
    const borrowed = try borrowGatewayBodyPoolChunk(runtime, chunk);
    body.appendBorrowedChunk(runtime.core.allocator, borrowed) catch |err| {
        borrowed.release.release();
        return err;
    };
}

/// Hands the extent `chunk` names to `body`'s streaming decoder. Once
/// borrowed, the extent belongs to the decoder on every path. The decoder
/// releases it, through the same release queue as an appended chunk, only
/// after decoding all of it, because that release refills the gateway's
/// HTTP/2 window (`decoder.zig`).
pub fn pushGatewayBodyPoolChunkToDecoder(
    runtime: *Runtime,
    decoder: *body_mod.Decoder,
    body: *Body,
    chunk: ipc.EgressBodyChunkView,
) !void {
    const borrowed = try borrowGatewayBodyPoolChunk(runtime, chunk);
    try decoder.pushBorrowed(runtime.core.allocator, body, borrowed);
}

/// Borrows the published extent `chunk` names, with a release that queues it
/// back to the gateway. Fails with `error.InvalidArgument` without a gateway
/// endpoint, or with the pool's error when the extent is not published.
fn borrowGatewayBodyPoolChunk(runtime: *Runtime, chunk: ipc.EgressBodyChunkView) !body_mod.BorrowedChunk {
    const endpoint = if (runtime.egress.state.shared) |*endpoint| endpoint else return error.InvalidArgument;
    return .{
        .bytes = try endpoint.body_pool.borrowContiguousChunk(chunk.body_pool_offset, chunk.len),
        .release = gateway_control.bodyPoolRelease(runtime, chunk.body_pool_offset, chunk.len),
    };
}
