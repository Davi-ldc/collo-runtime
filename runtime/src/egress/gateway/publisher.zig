//! Publication into a worker's egress endpoint: packets onto its completion ring, and body chunks
//! as body-pool extents plus the one ring packet that describes them. The gateway's loop thread
//! publishes, the worker process consumes the same ring and pool through shared memory, and the
//! worker's `publish_mutex` serializes publishers.
//!
//! A body batch is published whole or not at all. Its bytes go into pool slots the worker cannot
//! see yet, the slots become visible only once the descriptor packet is encoded, and if the ring
//! write still fails, the slots are freed before the worker can read a descriptor naming them.

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const active_fetch = @import("active_fetch.zig");
const body_credit = @import("collo_egress_client").body_credit;
const sessions = @import("sessions.zig");

/// One pool extent a body publication wrote, in descriptor order. The caller records it in the
/// worker's slot ledger (`sessions.Worker.recordSlotCredit`); when the worker returns the extent,
/// `credit` goes back to the engine that owns the fetch.
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

/// One worker's endpoint and the mutex that serializes publications to it.
pub const Target = struct {
    endpoint: *ipc.egress_shared.Endpoint,
    publish_mutex: *std.Thread.Mutex,
};

pub fn targetForWorker(worker: *sessions.Worker) Target {
    return .{
        .endpoint = &worker.endpoint,
        .publish_mutex = &worker.publish_mutex,
    };
}

pub fn queuePacket(
    worker: *sessions.Worker,
    bytes: []const u8,
) !ipc.egress_shared.PacketWriteResult {
    return queuePacketForTarget(targetForWorker(worker), bytes);
}

pub fn queuePacketForTarget(
    target: Target,
    bytes: []const u8,
) !ipc.egress_shared.PacketWriteResult {
    target.publish_mutex.lock();
    defer target.publish_mutex.unlock();
    return target.endpoint.completion.writePacket(bytes);
}

pub fn publishBodyChunkBatch(
    worker: *sessions.Worker,
    fetch_id: u64,
    body_id: u64,
    chunks: []const active_fetch.BodyChunkPayload,
    scratch: []u8,
    extents_out: []PublishedExtent,
) !BodyPublishResult {
    return publishBodyChunkBatchForTarget(targetForWorker(worker), fetch_id, body_id, chunks, scratch, extents_out);
}

/// Publishes `chunks` of one fetch as one batch and fills `extents_out`, which must hold
/// `ipc.egress_shared.body_pool_slot_count` entries, with the extents it wrote. On any error the
/// worker sees nothing of the batch. `error.EgressSharedRingFull` means the ring or the pool had
/// no room; any other error means a malformed batch or a broken endpoint.
pub fn publishBodyChunkBatchForTarget(
    target: Target,
    fetch_id: u64,
    body_id: u64,
    chunks: []const active_fetch.BodyChunkPayload,
    scratch: []u8,
    extents_out: []PublishedExtent,
) !BodyPublishResult {
    if (chunks.len == 0)
        return error.InvalidEgressPacket;
    if (chunks.len > ipc.egress.max_body_chunk_batch_count)
        return error.InvalidEgressPacket;

    // A transaction publishes at most one extent per pool slot, so segments,
    // descriptors and extents are bounded by `body_pool_slot_count`, far below
    // the message-level `ipc.egress.max_body_chunk_batch_count`. Arrays sized
    // by that cap would put more than a megabyte on the stack per call.
    var descriptors: [ipc.egress_shared.body_pool_slot_count]ipc.EgressBodyChunkView = undefined;
    var descriptor_count: usize = 0;
    if (extents_out.len < descriptors.len)
        return error.InvalidEgressPacket;

    // Reserve ring space for the worst-case descriptor count: a fragmented
    // pool can split every chunk into single-block segments, one descriptor
    // per pool block. One descriptor per chunk falls short exactly when the
    // pool fragments while the completion ring is nearly full, and the ring
    // write would then fail after the caller's body drain had consumed the
    // bytes. With the worst case reserved, `writePacket` below cannot fail for
    // lack of space: the publish mutex serializes producers, and the
    // consumer only frees space.
    var descriptor_count_reserved: usize = 0;
    for (chunks) |chunk| {
        if (chunk.bytes.len == 0)
            return error.EgressSharedPacketTooLarge;
        descriptor_count_reserved += blockCountForBytes(chunk.bytes.len);
    }
    if (descriptor_count_reserved > descriptors.len)
        return error.InvalidEgressPacket;

    target.publish_mutex.lock();
    defer target.publish_mutex.unlock();

    const descriptor_bytes = try std.math.mul(
        usize,
        descriptor_count_reserved,
        @sizeOf(ipc.EgressBodyChunkBatchDescriptor),
    );
    const packet_bytes = try std.math.add(
        usize,
        @sizeOf(ipc.EgressBodyChunkBatchHeader),
        descriptor_bytes,
    );
    try target.endpoint.completion.ensurePacketCapacity(packet_bytes, 0);

    // Releases are not drained here. Only the observed drain
    // (`drainWorkerPoolReleases` in `runtime/body_release_flow.zig`) may
    // advance the release cursor, because it turns each freed extent into a
    // flow-control credit. The space it reclaims is already visible to the
    // reservation below, and while the pool is full the preflight in
    // `body_pump.drainBody` pauses publication until that drain frees space
    // and wakes the shard.
    var transaction = try target.endpoint.body_pool.beginWriteTransaction();
    errdefer transaction.rollback();
    for (chunks) |chunk| {
        var segments_storage: [ipc.egress_shared.body_pool_slot_count]ipc.egress_shared.BodyPoolWriteTransaction.Segment = undefined;
        if (descriptor_count == descriptors.len)
            return error.InvalidEgressPacket;
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
                .billed_sent_total = chunk.billed_sent_total,
                .billed_received_total = chunk.billed_received_total,
                .cost_total = chunk.cost_total,
            };
            extents_out[descriptor_count] = .{
                .handle = segment.seq,
                .len = @intCast(segment.len),
                // The chunk's credit rides on its last extent, so the flow
                // window does not reopen before the worker has returned the
                // chunk's final bytes.
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
    const result = try target.endpoint.completion.writePacket(bytes);
    transaction.commit();
    return .{ .write = result, .extents = descriptor_count };
}

fn blockCountForBytes(bytes_len: usize) usize {
    const block = ipc.egress_shared.body_pool_block_size;
    return (bytes_len + block - 1) / block;
}
