//! The two pools of a session, both a `BodyPoolView`: fixed-size blocks the
//! producer fills and the consumer reads in place. On the body pool the
//! gateway produces response bodies for the worker; on the upload pool the
//! worker produces request bodies for the gateway. An extent travels as a
//! handle inside a ring packet, and `BodyPoolView` describes its life from
//! reservation to release. The worker runs its side of each pool on its event
//! loop thread and the gateway on its loop thread.
//!
//! The producer state (the slots, the block owners and the counters) is
//! written only by the producer and mapped read-only by the consumer. The
//! consumer state is the release queue, which both sides map writable: the
//! consumer fills entries and moves `release_write_seq`, and the producer
//! clears them and moves `release_read_seq` as it drains. Each side loads its
//! own cursor back from the queue, so on either pool the worker can rewrite
//! the cursor the gateway owns, and the gateway contains what that can do.
//! It drains the body pool's queue from its `release_read_seq` to the
//! worker's `release_write_seq`, each loaded once per drain, copies each
//! entry once and checks the copy against a slot it wrote: a rewound read
//! cursor replays entries, and a replayed entry frees only an extent that is
//! still published, which the worker could release anyway. On the upload
//! pool the gateway is the consumer, and `releaseChunk` loads its
//! `release_write_seq` back: a value that contradicts `release_read_seq`, or
//! one at its maximum, which cannot advance, marks the pool corrupt, and the
//! entry it writes is indexed modulo the queue's capacity, so the store stays
//! inside the queue.
//!
//! A consumer reads a published slot only through one copy
//! (`SlotSnapshot` in `slot_snapshot.zig`), validates the copy against the
//! pool's capacity and slices the extent from it. On the upload pool the
//! worker writes the slots and the gateway reads them, so a worker that
//! rewrites a slot after the gateway's load cannot move the slice.

const std = @import("std");

const FatalState = @import("region.zig").FatalState;
const RingMeta = @import("region.zig").RingMeta;
const Usage = @import("region.zig").Usage;
const SlotSnapshot = @import("slot_snapshot.zig").SlotSnapshot;

/// Bytes of the data region of each pool, the body pool and the upload pool.
pub const body_pool_capacity: usize = 8 * 1024 * 1024;
/// One block holds one HTTP/2 DATA frame payload. The egress engine never
/// advertises a SETTINGS_MAX_FRAME_SIZE above the protocol default,
/// `h2.default_max_frame_size`, so an HTTP/2 body chunk always fits one block
/// and each release returns one flow-control credit. This file imports no
/// HTTP code, so the gateway test `thin demux body pool block size matches
/// the h2 default max frame size` pins the two values together.
pub const body_pool_block_size: usize = 16 * 1024;
pub const body_pool_block_count: usize = body_pool_capacity / body_pool_block_size;
/// Every extent holds at least one block, so one slot per block is enough.
pub const body_pool_slot_count: usize = body_pool_block_count;
pub const body_pool_release_queue_capacity: usize = body_pool_slot_count;

comptime {
    // A consumer that releases each published extent once can never fill the
    // release queue, since at most one extent per slot is published at a time.
    std.debug.assert(body_pool_release_queue_capacity >= body_pool_slot_count);
    std.debug.assert(body_pool_capacity % body_pool_block_size == 0);
}

/// Names one published pool extent: the slot's generation in the high 32 bits
/// and its index plus one in the low 32 bits. Zero is never a handle, and
/// each reservation takes the pool's next 32-bit generation, so a stale handle
/// to a recycled slot fails validation.
pub const BodyPoolHandle = u64;

/// A slot is reserved while the producer fills its extent and published once
/// the consumer may read it.
pub const BodyPoolSlotState = enum(u32) {
    free = 0,
    reserved = 1,
    published = 2,
};

/// Written only by the pool's producer; a consumer reads one through
/// `SlotSnapshot`.
pub const BodyPoolSlot = extern struct {
    state: u32 = @intFromEnum(BodyPoolSlotState.free),
    generation: u32 = 0,
    offset: u32 = 0,
    len: u32 = 0,
    block_count: u32 = 0,
    _reserved0: u32 = 0,
    _reserved1: u64 = 0,
};

/// An extent the consumer is done with; the drain matches it against the
/// published slot by handle and length.
const BodyPoolReleaseEntry = extern struct {
    handle: BodyPoolHandle = 0,
    len: u32 = 0,
    _reserved0: u32 = 0,
};

/// Written only by the pool's producer. `block_owner` holds, per block, the
/// owning slot's index plus one, or 0 when the block is free;
/// `allocated_bytes` counts whole blocks; the next free-run search starts at
/// `search_block_index`.
pub const BodyPoolProducerState = extern struct {
    allocated_bytes: u64 = 0,
    dropped_packets: u64 = 0,
    fatal_state: u32 = 0,
    next_generation: u32 = 1,
    search_block_index: u32 = 0,
    _reserved0: u32 = 0,
    _reserved1: [3]u64 = .{ 0, 0, 0 },
    slots: [body_pool_slot_count]BodyPoolSlot = .{std.mem.zeroes(BodyPoolSlot)} ** body_pool_slot_count,
    block_owner: [body_pool_block_count]u32 = .{0} ** body_pool_block_count,
};

/// The release queue. The consumer fills entries and advances
/// `release_write_seq`; the producer clears entries and advances
/// `release_read_seq` as it drains, so both sides map this memfd writable.
pub const BodyPoolConsumerState = extern struct {
    release_write_seq: u64 = 0,
    release_read_seq: u64 = 0,
    fatal_state: u32 = 0,
    _reserved0: u32 = 0,
    _reserved1: [4]u64 = .{ 0, 0, 0, 0 },
    releases: [body_pool_release_queue_capacity]BodyPoolReleaseEntry =
        .{std.mem.zeroes(BodyPoolReleaseEntry)} ** body_pool_release_queue_capacity,
};

comptime {
    std.debug.assert(body_pool_capacity % body_pool_block_size == 0);
    std.debug.assert(body_pool_slot_count <= std.math.maxInt(u32));
    std.debug.assert(body_pool_release_queue_capacity <= std.math.maxInt(u32));

    std.debug.assert(@sizeOf(BodyPoolSlot) == 32);
    std.debug.assert(@offsetOf(BodyPoolSlot, "state") == 0);
    std.debug.assert(@offsetOf(BodyPoolSlot, "generation") == 4);
    std.debug.assert(@offsetOf(BodyPoolSlot, "offset") == 8);
    std.debug.assert(@offsetOf(BodyPoolSlot, "len") == 12);
    std.debug.assert(@offsetOf(BodyPoolSlot, "block_count") == 16);
    std.debug.assert(@offsetOf(BodyPoolSlot, "_reserved0") == 20);
    std.debug.assert(@offsetOf(BodyPoolSlot, "_reserved1") == 24);

    std.debug.assert(@sizeOf(BodyPoolReleaseEntry) == 16);
    std.debug.assert(@offsetOf(BodyPoolReleaseEntry, "handle") == 0);
    std.debug.assert(@offsetOf(BodyPoolReleaseEntry, "len") == 8);
    std.debug.assert(@offsetOf(BodyPoolReleaseEntry, "_reserved0") == 12);

    std.debug.assert(@sizeOf(BodyPoolProducerState) == 18488);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "allocated_bytes") == 0);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "dropped_packets") == 8);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "fatal_state") == 16);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "next_generation") == 20);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "search_block_index") == 24);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "_reserved0") == 28);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "_reserved1") == 32);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "slots") == 56);
    std.debug.assert(@offsetOf(BodyPoolProducerState, "block_owner") == 16440);

    std.debug.assert(@sizeOf(BodyPoolConsumerState) == 8248);
    std.debug.assert(@offsetOf(BodyPoolConsumerState, "release_write_seq") == 0);
    std.debug.assert(@offsetOf(BodyPoolConsumerState, "release_read_seq") == 8);
    std.debug.assert(@offsetOf(BodyPoolConsumerState, "fatal_state") == 16);
    std.debug.assert(@offsetOf(BodyPoolConsumerState, "_reserved0") == 20);
    std.debug.assert(@offsetOf(BodyPoolConsumerState, "_reserved1") == 24);
    std.debug.assert(@offsetOf(BodyPoolConsumerState, "releases") == 56);
}

/// One side's mapping of a pool. The producer reserves a free slot and a run
/// of contiguous free blocks, fills and publishes the extent and sends its
/// handle; the consumer borrows the extent and queues the handle for release;
/// the producer drains the queue and frees the blocks. Which of these a view
/// may do is its `access`; unless a method says otherwise, a call outside it
/// fails with `error.EgressSharedWrongSide`.
pub const BodyPoolView = struct {
    meta_bytes: []align(std.heap.page_size_min) u8,
    producer_bytes: []align(std.heap.page_size_min) u8,
    consumer_bytes: []align(std.heap.page_size_min) u8,
    data_bytes: []align(std.heap.page_size_min) u8,
    meta: *RingMeta,
    producer: *BodyPoolProducerState,
    consumer: *BodyPoolConsumerState,
    capacity_bytes: usize,
    access: BodyPoolAccess,
    /// The data memfd, held only by the gateway's body pool view for
    /// `punchFreeRange` and -1 in every other view.
    data_fd: std.posix.fd_t = -1,

    pub fn deinit(self: *BodyPoolView) void {
        if (self.meta_bytes.len != 0)
            std.posix.munmap(self.meta_bytes);
        if (self.producer_bytes.len != 0)
            std.posix.munmap(self.producer_bytes);
        if (self.consumer_bytes.len != 0)
            std.posix.munmap(self.consumer_bytes);
        if (self.data_bytes.len != 0)
            std.posix.munmap(self.data_bytes);
        if (self.data_fd >= 0)
            std.posix.close(self.data_fd);
        self.* = undefined;
    }

    /// Stamps the session into the meta. Only the gateway's view may; any
    /// other panics.
    pub fn setSession(self: *BodyPoolView, worker_session_id: u64, session_generation: u64) void {
        if (!self.access.write_session)
            std.debug.panic("egress shared body pool session mutation from wrong endpoint side", .{});
        @atomicStore(u64, &self.meta.worker_session_id, worker_session_id, .release);
        @atomicStore(u64, &self.meta.generation, session_generation, .release);
    }

    pub fn workerSessionId(self: *const BodyPoolView) u64 {
        return @atomicLoad(u64, &self.meta.worker_session_id, .acquire);
    }

    pub fn generation(self: *const BodyPoolView) u64 {
        return @atomicLoad(u64, &self.meta.generation, .acquire);
    }

    /// Copies `bytes` into one new extent, publishes it at once and returns
    /// its handle; fails as `reserveChunk` does.
    pub fn writeChunk(self: *BodyPoolView, bytes: []const u8) !u64 {
        var reservation = try self.reserveChunk(bytes.len);
        @memcpy(reservation.bytes(), bytes);
        try reservation.publish();
        reservation.commit();
        return reservation.handle;
    }

    /// Checks, without reserving, that a contiguous free run holds
    /// `bytes_len`; fails as `reserveChunk` does, but never for want of a slot.
    pub fn ensureWriteCapacity(self: *BodyPoolView, bytes_len: usize) !void {
        if (!self.access.write_chunks)
            return error.EgressSharedWrongSide;
        if (bytes_len == 0 or bytes_len > self.capacity())
            return error.EgressSharedPacketTooLarge;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        const block_count = blockCountForLen(bytes_len);
        _ = self.findFreeBlockRun(block_count) orelse {
            _ = @atomicRmw(u64, &self.producer.dropped_packets, .Add, 1, .monotonic);
            return error.EgressSharedRingFull;
        };
    }

    /// Starts a transaction whose extents become visible together; fails
    /// with `error.EgressSharedRingFatal` once the pool is fatal.
    pub fn beginWriteTransaction(self: *BodyPoolView) !BodyPoolWriteTransaction {
        if (!self.access.write_chunks)
            return error.EgressSharedWrongSide;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        return .{
            .pool = self,
        };
    }

    /// Reserves one extent of `len` bytes over contiguous blocks; the
    /// consumer cannot see it until it is published. Fails with
    /// `error.EgressSharedPacketTooLarge` for zero bytes or more than the
    /// pool, `error.EgressSharedRingFatal` once the pool is fatal, and
    /// `error.EgressSharedRingFull`, counted in `dropped_packets`, when no
    /// slot or no long enough run is free.
    pub fn reserveChunk(self: *BodyPoolView, len: usize) !BodyPoolReservation {
        if (!self.access.write_chunks)
            return error.EgressSharedWrongSide;
        if (len == 0 or len > self.capacity())
            return error.EgressSharedPacketTooLarge;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;

        const slot_index = self.findFreeSlot() orelse {
            _ = @atomicRmw(u64, &self.producer.dropped_packets, .Add, 1, .monotonic);
            return error.EgressSharedRingFull;
        };
        const block_count = blockCountForLen(len);
        const block_index = self.findFreeBlockRun(block_count) orelse {
            _ = @atomicRmw(u64, &self.producer.dropped_packets, .Add, 1, .monotonic);
            return error.EgressSharedRingFull;
        };
        return self.reserveChunkInRun(slot_index, block_index, block_count, len);
    }

    /// As `reserveChunk`, but takes the first free run that holds `max_len`
    /// or else the longest one, so the reservation's `len` may be shorter.
    pub fn reserveChunkAtMost(self: *BodyPoolView, max_len: usize) !BodyPoolReservation {
        if (!self.access.write_chunks)
            return error.EgressSharedWrongSide;
        if (max_len == 0 or max_len > self.capacity())
            return error.EgressSharedPacketTooLarge;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;

        const slot_index = self.findFreeSlot() orelse {
            _ = @atomicRmw(u64, &self.producer.dropped_packets, .Add, 1, .monotonic);
            return error.EgressSharedRingFull;
        };
        const max_blocks = blockCountForLen(max_len);
        const run = self.findFreeBlockRunAtMost(max_blocks) orelse {
            _ = @atomicRmw(u64, &self.producer.dropped_packets, .Add, 1, .monotonic);
            return error.EgressSharedRingFull;
        };
        const len = @min(max_len, run.block_count * body_pool_block_size);
        const block_count = blockCountForLen(len);
        std.debug.assert(block_count <= run.block_count);
        return self.reserveChunkInRun(slot_index, run.block_index, block_count, len);
    }

    fn reserveChunkInRun(
        self: *BodyPoolView,
        slot_index: usize,
        block_index: usize,
        block_count: usize,
        len: usize,
    ) BodyPoolReservation {
        const slot_generation = self.nextGeneration();
        const owner: u32 = @intCast(slot_index + 1);
        for (self.producer.block_owner[block_index..][0..block_count]) |*block_owner| {
            std.debug.assert(block_owner.* == 0);
            block_owner.* = owner;
        }
        const offset = block_index * body_pool_block_size;
        const slot = &self.producer.slots[slot_index];
        slot.generation = slot_generation;
        slot.offset = @intCast(offset);
        slot.len = @intCast(len);
        slot.block_count = @intCast(block_count);
        @atomicStore(u32, &slot.state, @intFromEnum(BodyPoolSlotState.reserved), .release);
        _ = @atomicRmw(
            u64,
            &self.producer.allocated_bytes,
            .Add,
            @as(u64, @intCast(block_count * body_pool_block_size)),
            .monotonic,
        );
        self.producer.search_block_index = @intCast((block_index + block_count) % body_pool_block_count);
        return .{
            .pool = self,
            .handle = packBodyPoolHandle(slot_index, slot_generation),
            .len = len,
            .active = true,
        };
    }

    /// Bytes held by reserved and published extents, in whole blocks, against
    /// the pool's capacity.
    pub fn usage(self: *BodyPoolView) !Usage {
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        return .{
            .used = @intCast(@atomicLoad(u64, &self.producer.allocated_bytes, .acquire)),
            .capacity = self.capacity(),
        };
    }

    /// Free blocks, counted without draining releases, for the producer's
    /// backpressure checks. Extents released but not yet drained still count
    /// as used, and only the producer takes blocks, so the count can only
    /// grow until the producer's next reservation. The free blocks need not
    /// be contiguous.
    pub fn freeBlocks(self: *const BodyPoolView) usize {
        const allocated = @atomicLoad(u64, &self.producer.allocated_bytes, .acquire);
        const used: usize = @intCast(@min(allocated, self.capacity_bytes));
        return (self.capacity_bytes - used) / body_pool_block_size;
    }

    /// Copies the published extent `handle`, exactly `out.len` bytes long,
    /// into `out`; fails as `borrowContiguousChunk` does.
    pub fn copyChunk(self: *BodyPoolView, handle: BodyPoolHandle, out: []u8) !void {
        if (!self.access.read_chunks)
            return error.EgressSharedWrongSide;
        const chunk = try self.borrowContiguousChunk(handle, out.len);
        @memcpy(out, chunk);
    }

    /// The bytes of the published extent `handle`, which must be exactly
    /// `len` bytes long. The slice points into the shared mapping and stays
    /// valid until this side releases the extent; the producer can still
    /// rewrite the bytes under it. Fails with `error.InvalidEgressSharedRing`
    /// when the handle names no published extent of that length.
    pub fn borrowContiguousChunk(self: *BodyPoolView, handle: BodyPoolHandle, len: usize) ![]u8 {
        if (!self.access.read_chunks)
            return error.EgressSharedWrongSide;
        const snapshot = try self.publishedSnapshot(handle, len);
        const extent = try snapshot.extent(self.capacity());
        return self.data()[extent.offset..][0..extent.len];
    }

    /// Checks that `handle` names a published extent of exactly `len` bytes,
    /// failing as `borrowContiguousChunk` does.
    pub fn validateChunkRange(self: *BodyPoolView, handle: BodyPoolHandle, len: usize) !void {
        if (!self.access.read_chunks and !self.access.release_chunks)
            return error.EgressSharedWrongSide;
        _ = try self.publishedSnapshot(handle, len);
    }

    /// Queues the published extent `handle` of `len` bytes for the producer
    /// to free. A handle or length that names no published extent, or a
    /// queue whose cursors disagree or cannot advance, marks the pool corrupt
    /// and fails with `error.InvalidEgressSharedRing`; a full queue fails
    /// with `error.EgressSharedRingFull`.
    pub fn releaseChunk(self: *BodyPoolView, handle: BodyPoolHandle, len: usize) !void {
        if (!self.access.release_chunks)
            return error.EgressSharedWrongSide;
        if (len == 0 or len > self.capacity()) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        _ = self.publishedSnapshot(handle, len) catch |err| {
            self.markFatal(.ring_corrupt);
            return err;
        };
        const read_seq = @atomicLoad(u64, &self.consumer.release_read_seq, .acquire);
        const write_seq = @atomicLoad(u64, &self.consumer.release_write_seq, .monotonic);
        if (write_seq < read_seq or write_seq - read_seq > body_pool_release_queue_capacity) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        // No consumer queues 2^64 releases, so a cursor at its maximum was
        // written by the other side, and stepping past it would overflow.
        const next_write_seq = std.math.add(u64, write_seq, 1) catch {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        };
        if (write_seq - read_seq == body_pool_release_queue_capacity) {
            return error.EgressSharedRingFull;
        }
        const index: usize = @intCast(write_seq % body_pool_release_queue_capacity);
        self.consumer.releases[index] = .{
            .handle = handle,
            .len = @intCast(len),
        };
        @atomicStore(u64, &self.consumer.release_write_seq, next_write_seq, .release);
    }

    fn capacity(self: *const BodyPoolView) usize {
        return self.capacity_bytes;
    }

    fn data(self: *BodyPoolView) []u8 {
        return self.data_bytes[0..self.capacity()];
    }

    fn markFatal(self: *BodyPoolView, state: FatalState) void {
        if (self.access.write_chunks) {
            @atomicStore(u32, &self.producer.fatal_state, @intFromEnum(state), .release);
        }
        if (self.access.release_chunks or self.access.drain_releases) {
            @atomicStore(u32, &self.consumer.fatal_state, @intFromEnum(state), .release);
        }
    }

    /// The producer's fatal state if set, else the consumer's; a value outside
    /// `FatalState` reads as `ring_corrupt`.
    pub fn fatalState(self: *const BodyPoolView) FatalState {
        const producer_raw = @atomicLoad(u32, &self.producer.fatal_state, .acquire);
        if (producer_raw != @intFromEnum(FatalState.none))
            return std.meta.intToEnum(FatalState, producer_raw) catch .ring_corrupt;
        const consumer_raw = @atomicLoad(u32, &self.consumer.fatal_state, .acquire);
        return std.meta.intToEnum(FatalState, consumer_raw) catch .ring_corrupt;
    }

    fn findFreeSlot(self: *BodyPoolView) ?usize {
        for (&self.producer.slots, 0..) |*slot, index| {
            const state = @atomicLoad(u32, &slot.state, .acquire);
            if (state == @intFromEnum(BodyPoolSlotState.free))
                return index;
        }
        return null;
    }

    fn findFreeBlockRun(self: *BodyPoolView, needed: usize) ?usize {
        std.debug.assert(needed != 0);
        std.debug.assert(needed <= body_pool_block_count);
        var start: usize = @min(self.producer.search_block_index, body_pool_block_count - 1);
        var scanned: usize = 0;
        while (scanned < body_pool_block_count) : (scanned += 1) {
            if (start + needed <= body_pool_block_count) {
                var run: usize = 0;
                while (run < needed and self.producer.block_owner[start + run] == 0) : (run += 1) {}
                if (run == needed)
                    return start;
            }
            start += 1;
            if (start == body_pool_block_count)
                start = 0;
        }
        return null;
    }

    fn findFreeBlockRunAtMost(self: *BodyPoolView, max_needed: usize) ?FreeBlockRun {
        std.debug.assert(max_needed != 0);
        std.debug.assert(max_needed <= body_pool_block_count);
        var best = FreeBlockRun{};
        var scanned: usize = 0;
        var index: usize = @min(self.producer.search_block_index, body_pool_block_count - 1);
        while (scanned < body_pool_block_count) {
            while (scanned < body_pool_block_count and self.producer.block_owner[index] != 0) {
                index = (index + 1) % body_pool_block_count;
                scanned += 1;
            }
            if (scanned == body_pool_block_count)
                break;

            const run_start = index;
            var run_count: usize = 0;
            while (scanned < body_pool_block_count and
                self.producer.block_owner[index] == 0 and
                run_start + run_count < body_pool_block_count)
            {
                run_count += 1;
                scanned += 1;
                index = (index + 1) % body_pool_block_count;
                if (run_count == max_needed)
                    return .{ .block_index = run_start, .block_count = max_needed };
            }
            if (run_count > best.block_count) {
                best = .{ .block_index = run_start, .block_count = run_count };
            }
        }
        if (best.block_count == 0)
            return null;
        return best;
    }

    fn nextGeneration(self: *BodyPoolView) u32 {
        var next_generation_value = self.producer.next_generation;
        if (next_generation_value == 0)
            next_generation_value = 1;
        self.producer.next_generation = next_generation_value +% 1;
        if (self.producer.next_generation == 0)
            self.producer.next_generation = 1;
        return next_generation_value;
    }

    /// One validated copy of the slot `handle` names, published and exactly
    /// `len` bytes long (`SlotSnapshot`). Fails with
    /// `error.InvalidEgressSharedRing` otherwise.
    fn publishedSnapshot(self: *const BodyPoolView, handle: BodyPoolHandle, len: usize) !SlotSnapshot {
        const decoded = try decodeBodyPoolHandle(handle);
        const snapshot = SlotSnapshot.load(&self.producer.slots[decoded.index]);
        try snapshot.validate(decoded.generation, len, self.capacity());
        return snapshot;
    }

    fn publishHandle(self: *BodyPoolView, handle: BodyPoolHandle) !void {
        const decoded = try decodeBodyPoolHandle(handle);
        const slot = &self.producer.slots[decoded.index];
        const state = @atomicLoad(u32, &slot.state, .acquire);
        if (state != @intFromEnum(BodyPoolSlotState.reserved) or slot.generation != decoded.generation) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        @atomicStore(u32, &slot.state, @intFromEnum(BodyPoolSlotState.published), .release);
    }

    fn freeHandle(self: *BodyPoolView, handle: BodyPoolHandle, expected_state: BodyPoolSlotState) !void {
        const decoded = try decodeBodyPoolHandle(handle);
        const slot = &self.producer.slots[decoded.index];
        const state = @atomicLoad(u32, &slot.state, .acquire);
        if (state != @intFromEnum(expected_state) or slot.generation != decoded.generation) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        self.freeSlot(decoded.index, slot);
    }

    fn freePublishedHandle(self: *BodyPoolView, handle: BodyPoolHandle, len: usize) !void {
        const decoded = try decodeBodyPoolHandle(handle);
        const slot = &self.producer.slots[decoded.index];
        const state = @atomicLoad(u32, &slot.state, .acquire);
        if (state != @intFromEnum(BodyPoolSlotState.published) or
            slot.generation != decoded.generation or
            slot.len != len)
        {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        self.freeSlot(decoded.index, slot);
    }

    fn freeSlot(self: *BodyPoolView, slot_index: usize, slot: *BodyPoolSlot) void {
        const owner: u32 = @intCast(slot_index + 1);
        const block_index = @as(usize, @intCast(slot.offset)) / body_pool_block_size;
        const block_count: usize = @intCast(slot.block_count);
        std.debug.assert(block_count != 0);
        std.debug.assert(block_index + block_count <= body_pool_block_count);
        for (self.producer.block_owner[block_index..][0..block_count]) |*block_owner| {
            std.debug.assert(block_owner.* == owner);
            block_owner.* = 0;
        }
        _ = @atomicRmw(
            u64,
            &self.producer.allocated_bytes,
            .Sub,
            @as(u64, @intCast(block_count * body_pool_block_size)),
            .monotonic,
        );
        slot.offset = 0;
        slot.len = 0;
        slot.block_count = 0;
        @atomicStore(u32, &slot.state, @intFromEnum(BodyPoolSlotState.free), .release);
        self.producer.search_block_index = @intCast(block_index);
    }

    /// One extent the consumer released, as the drain reports it: the handle
    /// the consumer queued and the block range the extent occupied, which
    /// `punchFreeRange` takes once the blocks are free.
    pub const ReleasedExtent = struct {
        handle: BodyPoolHandle,
        len: u32,
        block_index: u32,
        block_count: u32,
    };

    /// Frees every extent the consumer has queued for release and reports
    /// each to `observe` exactly once; returns how many it drained. Once the
    /// consumer has seen an extent's handle, its release is the only way its
    /// blocks return to the pool, and this is the only code that frees a
    /// released extent, so an observer that turns extents into flow-control
    /// credits sees every one. Fails with `error.EgressSharedRingFatal` once
    /// the pool is fatal. Queue cursors that disagree, or an entry that names
    /// no published extent of its length, mark the pool corrupt and fail with
    /// `error.InvalidEgressSharedRing`; the extents drained before stay freed.
    pub fn drainReleasedChunksObserved(
        self: *BodyPoolView,
        ctx: anytype,
        comptime observe: fn (@TypeOf(ctx), ReleasedExtent) void,
    ) !usize {
        if (!self.access.drain_releases)
            return error.EgressSharedWrongSide;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        var drained: usize = 0;
        var read_seq = @atomicLoad(u64, &self.consumer.release_read_seq, .monotonic);
        const write_seq = @atomicLoad(u64, &self.consumer.release_write_seq, .acquire);
        if (write_seq < read_seq or write_seq - read_seq > body_pool_release_queue_capacity) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        while (read_seq < write_seq) : (read_seq += 1) {
            const index: usize = @intCast(read_seq % body_pool_release_queue_capacity);
            const entry = self.consumer.releases[index];
            if (entry.handle == 0 or entry.len == 0 or entry._reserved0 != 0) {
                self.markFatal(.ring_corrupt);
                return error.InvalidEgressSharedRing;
            }
            // The block range is read before `freePublishedHandle` zeroes
            // the slot.
            const decoded = decodeBodyPoolHandle(entry.handle) catch {
                self.markFatal(.ring_corrupt);
                return error.InvalidEgressSharedRing;
            };
            const slot = &self.producer.slots[decoded.index];
            const extent = ReleasedExtent{
                .handle = entry.handle,
                .len = entry.len,
                .block_index = @intCast(@as(usize, @intCast(slot.offset)) / body_pool_block_size),
                .block_count = slot.block_count,
            };
            try self.freePublishedHandle(entry.handle, entry.len);
            observe(ctx, extent);
            drained += 1;
            self.consumer.releases[index] = .{};
            @atomicStore(u64, &self.consumer.release_read_seq, read_seq + 1, .release);
        }
        return drained;
    }

    /// As `drainReleasedChunksObserved` without an observer, for a caller
    /// that needs only the space back, such as a test; on a view that cannot
    /// drain it does nothing. Production code on the gateway's body pool must
    /// use the observed drain, since every extent released there carries a
    /// flow-control credit the gateway must return.
    pub fn drainReleasedChunks(self: *BodyPoolView) !void {
        if (!self.access.drain_releases)
            return;
        _ = try self.drainReleasedChunksObserved({}, observeNothing);
    }

    fn observeNothing(_: void, _: ReleasedExtent) void {}

    /// Returns the pages of a free block range to the kernel with
    /// FALLOC_FL_PUNCH_HOLE, keeping the memfd's size: the size seals allow
    /// it, where a write seal would not. When to punch is the caller's policy
    /// (`drainWorkerPoolReleases` in `egress/gateway/runtime/body_release_flow.zig`).
    /// Fails with `error.EgressSharedWrongSide` on a view without `data_fd`
    /// and with `error.InvalidEgressSharedRing` when a block in the range is
    /// owned or the range leaves the pool.
    pub fn punchFreeRange(self: *BodyPoolView, block_index: usize, block_count: usize) !void {
        if (self.data_fd < 0)
            return error.EgressSharedWrongSide;
        if (block_count == 0 or block_index + block_count > body_pool_block_count)
            return error.InvalidEgressSharedRing;
        for (self.producer.block_owner[block_index..][0..block_count]) |owner| {
            if (owner != 0)
                return error.InvalidEgressSharedRing;
        }
        const offset: i64 = @intCast(block_index * body_pool_block_size);
        const len: i64 = @intCast(block_count * body_pool_block_size);
        const rc = std.os.linux.fallocate(
            self.data_fd,
            std.os.linux.FALLOC.FL_PUNCH_HOLE | std.os.linux.FALLOC.FL_KEEP_SIZE,
            offset,
            len,
        );
        switch (std.os.linux.E.init(rc)) {
            .SUCCESS => {},
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
    }
};

/// The slot index behind a handle, for producer tables indexed by slot such
/// as the gateway's slot ledger (`egress/gateway/sessions.zig`). Fails with
/// `error.InvalidEgressSharedRing` on a malformed handle.
pub fn slotIndexForHandle(handle: BodyPoolHandle) !usize {
    const decoded = try decodeBodyPoolHandle(handle);
    return decoded.index;
}

const DecodedBodyPoolHandle = struct {
    index: usize,
    generation: u32,
};

const FreeBlockRun = struct {
    block_index: usize = 0,
    block_count: usize = 0,
};

fn packBodyPoolHandle(index: usize, generation: u32) BodyPoolHandle {
    std.debug.assert(index < body_pool_slot_count);
    std.debug.assert(generation != 0);
    return (@as(u64, generation) << 32) | @as(u64, @intCast(index + 1));
}

fn decodeBodyPoolHandle(handle: BodyPoolHandle) !DecodedBodyPoolHandle {
    if (handle == 0)
        return error.InvalidEgressSharedRing;
    const generation: u32 = @intCast(handle >> 32);
    const raw_index: u32 = @truncate(handle);
    if (generation == 0 or raw_index == 0)
        return error.InvalidEgressSharedRing;
    const index: usize = @intCast(raw_index - 1);
    if (index >= body_pool_slot_count)
        return error.InvalidEgressSharedRing;
    return .{
        .index = index,
        .generation = generation,
    };
}

fn blockCountForLen(len: usize) usize {
    std.debug.assert(len != 0);
    std.debug.assert(len <= body_pool_capacity);
    return (len + body_pool_block_size - 1) / body_pool_block_size;
}

/// One reserved extent: fill `bytes`, `publish` it, and `commit` once its
/// handle is on its way to the consumer. Until `commit`, `rollback` frees it,
/// published or not.
pub const BodyPoolReservation = struct {
    pool: *BodyPoolView,
    handle: BodyPoolHandle,
    len: usize,
    active: bool = false,
    published: bool = false,

    pub fn bytes(self: *const BodyPoolReservation) []u8 {
        std.debug.assert(self.active);
        const decoded = decodeBodyPoolHandle(self.handle) catch unreachable;
        const slot = &self.pool.producer.slots[decoded.index];
        std.debug.assert(slot.generation == decoded.generation);
        std.debug.assert(slot.len == @as(u32, @intCast(self.len)));
        const offset: usize = @intCast(slot.offset);
        return self.pool.data()[offset..][0..self.len];
    }

    pub fn publish(self: *BodyPoolReservation) !void {
        std.debug.assert(self.active);
        std.debug.assert(!self.published);
        try self.pool.publishHandle(self.handle);
        self.published = true;
    }

    pub fn commit(self: *BodyPoolReservation) void {
        std.debug.assert(self.active);
        std.debug.assert(self.published);
        self.active = false;
    }

    pub fn rollback(self: *BodyPoolReservation) void {
        if (!self.active)
            return;
        const expected_state: BodyPoolSlotState = if (self.published) .published else .reserved;
        self.pool.freeHandle(self.handle, expected_state) catch |err| {
            std.log.warn("egress shared body pool reservation rollback failed: {s}", .{
                @errorName(err),
            });
        };
        self.active = false;
    }
};

/// Extents written as one batch: each is reserved and filled while the
/// consumer cannot see it, `publish` makes them all visible, and `commit`
/// ends the transaction once their handles are on their way to the consumer.
/// Until `commit`, `rollback` frees every extent the transaction holds.
pub const BodyPoolWriteTransaction = struct {
    pool: *BodyPoolView,
    handles: [body_pool_transaction_slot_capacity]BodyPoolHandle =
        .{0} ** body_pool_transaction_slot_capacity,
    handle_count: usize = 0,
    published: bool = false,
    active: bool = true,

    /// One handle per pool slot, so a transaction can hold every slot.
    pub const body_pool_transaction_slot_capacity: usize = body_pool_slot_count;

    /// One extent of a segmented write; `seq` is its handle.
    pub const Segment = struct {
        seq: u64,
        len: usize,
    };

    /// Reserves one contiguous extent, copies `bytes` into it and returns its
    /// handle. Fails with `error.InvalidEgressPacket` when the transaction
    /// already holds `body_pool_transaction_slot_capacity` extents, else as
    /// `BodyPoolView.reserveChunk` does.
    pub fn writeChunk(self: *BodyPoolWriteTransaction, bytes: []const u8) !u64 {
        std.debug.assert(self.active);
        std.debug.assert(!self.published);
        if (self.handle_count == self.handles.len)
            return error.InvalidEgressPacket;
        var reservation = try self.pool.reserveChunk(bytes.len);
        errdefer reservation.rollback();
        @memcpy(reservation.bytes(), bytes);
        self.handles[self.handle_count] = reservation.handle;
        self.handle_count += 1;
        reservation.active = false;
        return reservation.handle;
    }

    /// Writes `bytes` as one extent when a long enough free run exists, and
    /// otherwise in order over as many free runs as it takes; returns the
    /// segments as a prefix of `out`. Fails with `error.InvalidEgressPacket`
    /// when `out` or the transaction runs out of room and as
    /// `BodyPoolView.reserveChunk` does otherwise, freeing every segment of
    /// this call.
    pub fn writeChunkContiguousSegments(
        self: *BodyPoolWriteTransaction,
        bytes: []const u8,
        out: []Segment,
    ) ![]const Segment {
        std.debug.assert(self.active);
        std.debug.assert(!self.published);
        if (out.len == 0)
            return error.InvalidEgressPacket;
        const written_seq = self.writeChunk(bytes) catch |err| switch (err) {
            error.EgressSharedRingFull => null,
            else => return err,
        };
        if (written_seq) |seq| {
            out[0] = .{ .seq = seq, .len = bytes.len };
            return out[0..1];
        }

        var offset: usize = 0;
        var segment_count: usize = 0;
        errdefer {
            const expected_state: BodyPoolSlotState = if (self.published) .published else .reserved;
            while (segment_count != 0) {
                segment_count -= 1;
                self.handle_count -= 1;
                self.pool.freeHandle(self.handles[self.handle_count], expected_state) catch |free_err| {
                    std.log.warn("egress shared body pool segment rollback failed: {s}", .{
                        @errorName(free_err),
                    });
                };
                self.handles[self.handle_count] = 0;
            }
        }
        while (offset < bytes.len) {
            if (segment_count == out.len or self.handle_count == self.handles.len)
                return error.InvalidEgressPacket;
            var reservation = try self.pool.reserveChunkAtMost(bytes.len - offset);
            errdefer reservation.rollback();
            const segment_len = reservation.len;
            @memcpy(reservation.bytes(), bytes[offset..][0..segment_len]);
            out[segment_count] = .{ .seq = reservation.handle, .len = segment_len };
            self.handles[self.handle_count] = reservation.handle;
            self.handle_count += 1;
            segment_count += 1;
            offset += segment_len;
            reservation.active = false;
        }
        return out[0..segment_count];
    }

    pub fn publish(self: *BodyPoolWriteTransaction) !void {
        std.debug.assert(self.active);
        std.debug.assert(!self.published);
        for (self.handles[0..self.handle_count]) |handle| {
            try self.pool.publishHandle(handle);
        }
        self.published = true;
    }

    pub fn commit(self: *BodyPoolWriteTransaction) void {
        std.debug.assert(self.active);
        std.debug.assert(self.published);
        self.active = false;
    }

    pub fn rollback(self: *BodyPoolWriteTransaction) void {
        if (!self.active)
            return;
        const expected_state: BodyPoolSlotState = if (self.published) .published else .reserved;
        for (self.handles[0..self.handle_count]) |handle| {
            self.pool.freeHandle(handle, expected_state) catch |err| {
                std.log.warn("egress shared body pool rollback failed: {s}", .{@errorName(err)});
            };
        }
        self.active = false;
    }
};

pub const BodyPoolAccess = struct {
    write_chunks: bool = false,
    read_chunks: bool = false,
    release_chunks: bool = false,
    drain_releases: bool = false,
    write_session: bool = false,
};
