//! Publication into a worker's egress endpoint: packets onto its completion ring, and body chunks
//! as body-pool extents plus the one ring packet that describes them. The gateway's loop thread is
//! the endpoint's only producer, and the worker process consumes the same ring and pool through
//! shared memory. A caller that publishes from more than one thread, such as a test's stand-in
//! gateway, serializes the calls itself.
//!
//! A body batch is published whole or not at all. Its bytes go into pool slots the worker cannot
//! see yet, the slots become visible only once the descriptor packet is encoded, and if the ring
//! write still fails, the slots are freed before the worker can read a descriptor naming them.

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const body_credit = @import("collo_egress_client").body_credit;

/// One body chunk to publish and the engine flow-control credit its bytes carry. The credit rides
/// the last pool extent the chunk lands in, and the gateway returns it to the engine when the
/// worker returns that extent, so the worker's release is the credit's acknowledgement.
pub const BodyChunkPayload = struct {
    bytes: []const u8,
    credit: body_credit.Handle = .none,
};

/// One pool extent a body publication wrote, in descriptor order, with the credit it carries.
pub const PublishedExtent = struct {
    handle: ipc.egress_shared.BodyPoolHandle,
    len: u32,
    credit: body_credit.Handle,
};

pub const BodyPublishResult = struct {
    write: ipc.egress_shared.PacketWriteResult,
    /// How many leading entries of the caller's `extents_out` the publication filled.
    extents: usize,
};

/// Writes `bytes` onto `endpoint`'s completion ring as one packet. Fails with
/// `error.EgressSharedRingFull` when the ring has no room, and with the ring's own errors when
/// its shared state is broken.
pub fn queuePacket(
    endpoint: *ipc.egress_shared.Endpoint,
    bytes: []const u8,
) !ipc.egress_shared.PacketWriteResult {
    return endpoint.completion.writePacket(bytes);
}

/// Pool blocks, and so ring descriptors, `bytes_len` bytes take at most when published.
pub fn blockCountForBytes(bytes_len: usize) usize {
    return std.math.divCeil(usize, bytes_len, ipc.egress_shared.body_pool_block_size) catch unreachable;
}

/// Publishes `chunks` of one fetch as one batch and fills `extents_out`, which must hold
/// `ipc.egress_shared.body_pool_slot_count` entries, with the extents it wrote. On any error the
/// worker sees nothing of the batch. `error.EgressSharedRingFull` means the ring or the pool had
/// no room; any other error means a malformed batch or a broken endpoint.
pub fn publishBodyChunkBatch(
    endpoint: *ipc.egress_shared.Endpoint,
    fetch_id: u64,
    body_id: u64,
    chunks: []const BodyChunkPayload,
    scratch: []u8,
    extents_out: []PublishedExtent,
) !BodyPublishResult {
    if (chunks.len == 0)
        return error.InvalidEgressPacket;
    if (chunks.len > ipc.egress.max_body_chunk_batch_count)
        return error.InvalidEgressPacket;

    // A transaction publishes at most one extent per pool slot, so segments, descriptors and
    // extents are bounded by `body_pool_slot_count`, which is also the message-level
    // `ipc.egress.max_body_chunk_batch_count`.
    var descriptors: [ipc.egress_shared.body_pool_slot_count]ipc.EgressBodyChunkView = undefined;
    var descriptor_count: usize = 0;
    if (extents_out.len < descriptors.len)
        return error.InvalidEgressPacket;

    // Reserve ring space for the worst-case descriptor count: a fragmented pool can split every
    // chunk into single-block segments, one descriptor per pool block. With the worst case
    // reserved, `writePacket` below cannot fail for lack of space, since the gateway is the
    // ring's only producer and the consumer only frees space.
    var descriptor_count_reserved: usize = 0;
    for (chunks) |chunk| {
        if (chunk.bytes.len == 0)
            return error.InvalidEgressPacket;
        descriptor_count_reserved += blockCountForBytes(chunk.bytes.len);
    }
    if (descriptor_count_reserved > descriptors.len)
        return error.InvalidEgressPacket;

    const packet_bytes = @sizeOf(ipc.EgressBodyChunkBatchHeader) +
        descriptor_count_reserved * @sizeOf(ipc.EgressBodyChunkBatchDescriptor);
    try endpoint.completion.ensurePacketCapacity(packet_bytes, 0);

    // Releases are not drained here. Only the release drain (`runtime/release_flow.zig`) may
    // advance the release cursor, because it turns each freed extent into a flow-control credit.
    // The space it reclaims is already visible to the reservation below.
    var transaction = try endpoint.body_pool.beginWriteTransaction();
    errdefer transaction.rollback();
    for (chunks) |chunk| {
        var segments_storage: [ipc.egress_shared.body_pool_slot_count]ipc.egress_shared.BodyPoolWriteTransaction.Segment = undefined;
        const segments = try transaction.writeChunkContiguousSegments(
            chunk.bytes,
            segments_storage[0 .. descriptors.len - descriptor_count],
        );
        for (segments, 0..) |segment, segment_index| {
            if (descriptor_count == descriptors.len)
                return error.InvalidEgressPacket;
            descriptors[descriptor_count] = .{
                .fetch_id = fetch_id,
                .body_id = body_id,
                .body_pool_offset = segment.seq,
                .len = segment.len,
            };
            extents_out[descriptor_count] = .{
                .handle = segment.seq,
                .len = @intCast(segment.len),
                // The chunk's credit rides on its last extent, so the flow window does not
                // reopen before the worker has returned the chunk's final bytes.
                .credit = if (segment_index == segments.len - 1) chunk.credit else .none,
            };
            descriptor_count += 1;
        }
    }

    const bytes = try ipc.encodeEgressBodyChunkBatchInto(
        scratch,
        .{
            .chunks = descriptors[0..descriptor_count],
            .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
        },
    );
    try transaction.publish();
    const result = try endpoint.completion.writePacket(bytes);
    transaction.commit();
    return .{ .write = result, .extents = descriptor_count };
}

/// Completion-ring bytes one batch publication of `descriptor_count` descriptors needs at most:
/// the encoded packet plus the ring's framing, which the body drain reserves before it takes a
/// chunk it cannot put back.
pub fn worstCaseBatchPacketBytes(descriptor_count: usize) usize {
    return ringRecordBytes(@sizeOf(ipc.EgressBodyChunkBatchHeader) +
        descriptor_count * @sizeOf(ipc.EgressBodyChunkBatchDescriptor));
}

/// Completion-ring bytes a packet of `packet_len` bytes takes at most: the packet and the ring's
/// framing.
pub fn ringRecordBytes(packet_len: usize) usize {
    return packet_len + ring_packet_overhead_bytes;
}

/// The largest response head the gateway writes: the head's fixed part with the status text, the
/// final URL and the header bytes at the caps the codec enforces (`encodeEgressFetchHeadInto`).
pub const head_packet_bytes_max: usize = @sizeOf(ipc.EgressFetchHeadHeader) +
    ipc.fetch_limits.response_status_text_bytes_max +
    ipc.fetch_limits.response_url_bytes_max +
    ipc.fetch_limits.response_headers_bytes_max;

/// The largest terminal packet of a fetch: its body end, the acknowledgment of its stop, or its
/// error with a message at the codec's cap (`encodeEgressFetchErrorInto`).
pub const terminal_packet_bytes_max: usize = @max(
    @max(@sizeOf(ipc.EgressBodyEnd), @sizeOf(ipc.EgressAbortAck)),
    @sizeOf(ipc.EgressFetchErrorHeader) + ipc.fetch_limits.response_error_message_bytes_max,
);

/// Completion-ring bytes the body batches a worker has not read can take at most. Each unread
/// descriptor names an extent the worker has not returned, so they number at most the pool's
/// blocks, and each batch packet carries at least one.
pub const unread_batch_bytes_max: usize = ipc.egress_shared.body_pool_slot_count * worstCaseBatchPacketBytes(1);

/// The ring's per-packet framing in `ringRecordBytes`. The ring's frame header (`FrameHeader` in
/// `common/ipc/egress_shared/packet_ring.zig`) is 8 bytes; the margin keeps this file independent
/// of the ring's private layout.
const ring_packet_overhead_bytes: usize = 16;
