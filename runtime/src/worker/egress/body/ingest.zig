//! Feeds gateway body-pool extents to fetch bodies, on the worker's event loop
//! thread. An extent is read in place from the shared pool. Its release, which
//! queues it back for the gateway to reuse, is the worker's flow-control
//! acknowledgment, so it fires exactly once, after the last reader is done
//! with the bytes.

const ipc = @import("collo_ipc");
const egress_core = @import("collo_egress_core");
const egress_context = @import("../context.zig");
const egress_state = @import("../state.zig");
const common = @import("common.zig");

const FetchBody = common.FetchBody;

/// Appends the extent `chunk` names to `body` as a borrowed chunk and returns
/// whether a reader became ready. The body owns the extent on success. A
/// failed append releases the extent before the error returns, and a failed
/// borrow took nothing, so the caller never releases it.
pub fn appendGatewayBodyPoolChunk(
    runtime: *egress_context.Context,
    body: *FetchBody,
    chunk: ipc.EgressBodyChunkView,
    credit: egress_core.body_credit.Handle,
) !bool {
    const borrowed = try borrowGatewayBodyPoolChunk(runtime, chunk);
    return body.appendBorrowedChunk(runtime.allocator, borrowed, credit) catch |err| switch (err) {
        else => {
            borrowed.release.release();
            return err;
        },
    };
}

/// Hands the extent `chunk` names to `body`'s streaming decoder and returns
/// whether a reader became ready. Once borrowed, the extent belongs to the
/// decoder on every path. The decoder releases it, through the same release
/// queue as an appended chunk, only after decoding all of it, because that
/// release refills the gateway's HTTP/2 window (`encoded_body.zig`).
pub fn pushGatewayBodyPoolChunkToDecoder(
    runtime: *egress_context.Context,
    decoder: *egress_state.BodyDecoder,
    body: *FetchBody,
    chunk: ipc.EgressBodyChunkView,
) !bool {
    const borrowed = try borrowGatewayBodyPoolChunk(runtime, chunk);
    return decoder.pushBorrowed(runtime.allocator, body, borrowed);
}

/// Borrows the published extent `chunk` names, with a release that queues it
/// back to the gateway. Fails with `error.InvalidArgument` without a gateway
/// endpoint, or with the pool's error when the extent is not published.
fn borrowGatewayBodyPoolChunk(
    runtime: *egress_context.Context,
    chunk: ipc.EgressBodyChunkView,
) !egress_core.fetch_body.BorrowedChunk {
    const endpoint = if (runtime.egress_state.shared) |*endpoint| endpoint else return error.InvalidArgument;
    const borrowed_bytes = try endpoint.body_pool.borrowContiguousChunk(
        chunk.body_pool_offset,
        chunk.len,
    );
    return .{
        .bytes = borrowed_bytes,
        .release = .{
            .context = &runtime.egress_state.body_pool_release_context,
            .seq = chunk.body_pool_offset,
            .len = chunk.len,
            .release_fn = egress_state.BodyPoolReleaseContext.release,
        },
    };
}
