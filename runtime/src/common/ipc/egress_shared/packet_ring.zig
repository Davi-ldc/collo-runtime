//! The two packet rings of a session, both a `RingView`. On the command ring
//! the worker is the producer, writing the producer state and the data, and
//! the gateway is the consumer, writing the consumer state; on the completion
//! ring the gateway produces and the worker consumes. A record is a
//! `FrameHeader` and the packet bytes, written whole and wrapping at the end
//! of the data region, and `write_seq` and `read_seq` count record bytes
//! since creation. The worker runs its side of each ring on its event loop
//! thread and the gateway on its loop thread.
//!
//! A reader loads the producer's `write_seq` once per packet, copies the
//! frame header once, checks that copy and copies the packet out before it
//! returns it, so a producer that rewrites the ring during a read can garble
//! the packet's bytes but never its length or a cursor. A writer loads the
//! consumer's `read_seq` once for its space check and once more after it
//! publishes, only to decide whether the consumer needs a wake. Cursors that
//! contradict each other mark the ring fatal.

const std = @import("std");

const FatalState = @import("region.zig").FatalState;
const RingMeta = @import("region.zig").RingMeta;
const Usage = @import("region.zig").Usage;

pub const command_ring_capacity: usize = 1024 * 1024;
pub const completion_ring_capacity: usize = 4 * 1024 * 1024;
/// The largest packet either ring accepts.
pub const max_packet_bytes: usize = 1024 * 1024;
/// Command ring space that fetch starts and upload batches leave free, so the
/// cancel and release commands the worker writes without a reserve still fit
/// when those fill the ring.
pub const command_control_reserve_bytes: usize = 64 * 1024;

const frame_header_size = @sizeOf(FrameHeader);

/// Written only by the ring's producer. `write_seq` counts the record bytes
/// published since creation; `dropped_packets` counts writes refused for space.
pub const RingProducerState = extern struct {
    write_seq: u64 = 0,
    dropped_packets: u64 = 0,
    fatal_state: u32 = 0,
    _reserved0: u32 = 0,
    _reserved1: [4]u64 = .{ 0, 0, 0, 0 },
};

/// Written only by the ring's consumer. `read_seq` counts the record bytes
/// consumed since creation.
pub const RingConsumerState = extern struct {
    read_seq: u64 = 0,
    fatal_state: u32 = 0,
    _reserved0: u32 = 0,
    _reserved1: [4]u64 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(RingProducerState) == 56);
    std.debug.assert(@offsetOf(RingProducerState, "write_seq") == 0);
    std.debug.assert(@offsetOf(RingProducerState, "dropped_packets") == 8);
    std.debug.assert(@offsetOf(RingProducerState, "fatal_state") == 16);
    std.debug.assert(@offsetOf(RingProducerState, "_reserved0") == 20);
    std.debug.assert(@offsetOf(RingProducerState, "_reserved1") == 24);

    std.debug.assert(@sizeOf(RingConsumerState) == 48);
    std.debug.assert(@offsetOf(RingConsumerState, "read_seq") == 0);
    std.debug.assert(@offsetOf(RingConsumerState, "fatal_state") == 8);
    std.debug.assert(@offsetOf(RingConsumerState, "_reserved0") == 12);
    std.debug.assert(@offsetOf(RingConsumerState, "_reserved1") == 16);
}

pub const PacketWriteResult = struct {
    /// True when this write took the ring from empty to non-empty.
    ring_was_empty: bool,
    /// True when the consumer may have found the ring empty and gone to sleep
    /// before this packet was visible, so it needs a wake
    /// (`notifyAfterPacketWrite`).
    eventfd_notify_required: bool,
};

/// Precedes every packet in a ring; `flags` must be zero. Records are not
/// aligned, so a header may wrap around the end of the data region.
const FrameHeader = extern struct {
    len: u32,
    flags: u32 = 0,
};

/// One side's mapping of a packet ring. A record is a `FrameHeader` and the
/// packet bytes, written whole and wrapping at the end of the data region.
/// Which of writing and reading a view may do is its `access`; unless a method
/// says otherwise, a call outside it fails with `error.EgressSharedWrongSide`.
pub const RingView = struct {
    meta_bytes: []align(std.heap.page_size_min) u8,
    producer_bytes: []align(std.heap.page_size_min) u8,
    consumer_bytes: []align(std.heap.page_size_min) u8,
    data_bytes: []align(std.heap.page_size_min) u8,
    meta: *RingMeta,
    producer: *RingProducerState,
    consumer: *RingConsumerState,
    capacity_bytes: usize,
    access: RingAccess,

    pub fn deinit(self: *RingView) void {
        if (self.meta_bytes.len != 0)
            std.posix.munmap(self.meta_bytes);
        if (self.producer_bytes.len != 0)
            std.posix.munmap(self.producer_bytes);
        if (self.consumer_bytes.len != 0)
            std.posix.munmap(self.consumer_bytes);
        if (self.data_bytes.len != 0)
            std.posix.munmap(self.data_bytes);
        self.* = undefined;
    }

    /// Stamps the session into the meta. Only the gateway's view may; any
    /// other panics.
    pub fn setSession(self: *RingView, worker_session_id: u64, session_generation: u64) void {
        if (!self.access.write_session)
            std.debug.panic("egress shared ring session mutation from wrong endpoint side", .{});
        @atomicStore(u64, &self.meta.worker_session_id, worker_session_id, .release);
        @atomicStore(u64, &self.meta.generation, session_generation, .release);
    }

    pub fn workerSessionId(self: *const RingView) u64 {
        return @atomicLoad(u64, &self.meta.worker_session_id, .acquire);
    }

    pub fn generation(self: *const RingView) u64 {
        return @atomicLoad(u64, &self.meta.generation, .acquire);
    }

    /// Records `state` in the state this side writes: the producer's for the
    /// writer, the consumer's for the reader.
    pub fn markFatal(self: *RingView, state: FatalState) void {
        if (self.access.write_packets) {
            @atomicStore(u32, &self.producer.fatal_state, @intFromEnum(state), .release);
        } else {
            @atomicStore(u32, &self.consumer.fatal_state, @intFromEnum(state), .release);
        }
    }

    /// The producer's fatal state if set, else the consumer's; a value outside
    /// `FatalState` reads as `ring_corrupt`.
    pub fn fatalState(self: *const RingView) FatalState {
        const producer_raw = @atomicLoad(u32, &self.producer.fatal_state, .acquire);
        if (producer_raw != @intFromEnum(FatalState.none))
            return std.meta.intToEnum(FatalState, producer_raw) catch .ring_corrupt;
        const consumer_raw = @atomicLoad(u32, &self.consumer.fatal_state, .acquire);
        return std.meta.intToEnum(FatalState, consumer_raw) catch .ring_corrupt;
    }

    pub fn writePacket(self: *RingView, packet: []const u8) !PacketWriteResult {
        return self.writePacketReserved(packet, 0);
    }

    /// Writes one packet and leaves at least `reserved_free_bytes` of the ring
    /// free after it. Fails with `error.EgressSharedPacketTooLarge` for an
    /// empty packet or one over `max_packet_bytes` or the ring,
    /// `error.EgressSharedRingFatal` once the ring is fatal,
    /// `error.InvalidEgressSharedRing`, marking the ring corrupt, when the
    /// cursors disagree, and `error.EgressSharedRingFull`, counted in
    /// `dropped_packets`, when the packet does not fit.
    pub fn writePacketReserved(
        self: *RingView,
        packet: []const u8,
        reserved_free_bytes: usize,
    ) !PacketWriteResult {
        if (!self.access.write_packets)
            return error.EgressSharedWrongSide;
        if (packet.len == 0 or packet.len > max_packet_bytes)
            return error.EgressSharedPacketTooLarge;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        const ring_capacity = self.capacity();
        const record_len = checkedRecordLen(packet.len) catch return error.EgressSharedPacketTooLarge;
        if (record_len > ring_capacity)
            return error.EgressSharedPacketTooLarge;

        const read_seq = @atomicLoad(u64, &self.consumer.read_seq, .acquire);
        const write_seq = @atomicLoad(u64, &self.producer.write_seq, .monotonic);
        if (write_seq < read_seq) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        const used = write_seq - read_seq;
        const ring_was_empty = used == 0;
        if (used > ring_capacity) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        const available = ring_capacity - @as(usize, @intCast(used));
        if (reserved_free_bytes > available or record_len > available - reserved_free_bytes) {
            _ = @atomicRmw(u64, &self.producer.dropped_packets, .Add, 1, .monotonic);
            return error.EgressSharedRingFull;
        }

        var header = FrameHeader{ .len = @intCast(packet.len) };
        const offset: usize = @intCast(write_seq % ring_capacity);
        self.copyInto(offset, std.mem.asBytes(&header));
        self.copyInto((offset + frame_header_size) % ring_capacity, packet);
        @atomicStore(u64, &self.producer.write_seq, write_seq + @as(u64, @intCast(record_len)), .release);
        const read_seq_after = @atomicLoad(u64, &self.consumer.read_seq, .acquire);
        // A consumer that advanced during this write may have drained the
        // older packets and found the ring empty before `write_seq` moved, so
        // it needs a wake just as an empty ring's consumer does.
        return .{
            .ring_was_empty = ring_was_empty,
            .eventfd_notify_required = ring_was_empty or read_seq_after != read_seq,
        };
    }

    /// Checks, without writing, that `writePacketReserved` would take a
    /// `packet_len` packet now; fails as it would.
    pub fn ensurePacketCapacity(self: *RingView, packet_len: usize, reserved_free_bytes: usize) !void {
        if (!self.access.write_packets)
            return error.EgressSharedWrongSide;
        if (packet_len == 0 or packet_len > max_packet_bytes)
            return error.EgressSharedPacketTooLarge;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        const ring_capacity = self.capacity();
        const record_len = checkedRecordLen(packet_len) catch return error.EgressSharedPacketTooLarge;
        if (record_len > ring_capacity)
            return error.EgressSharedPacketTooLarge;

        const read_seq = @atomicLoad(u64, &self.consumer.read_seq, .acquire);
        const write_seq = @atomicLoad(u64, &self.producer.write_seq, .acquire);
        if (write_seq < read_seq) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        const used = write_seq - read_seq;
        if (used > ring_capacity) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        const available = ring_capacity - @as(usize, @intCast(used));
        if (reserved_free_bytes > available or record_len > available - reserved_free_bytes) {
            _ = @atomicRmw(u64, &self.producer.dropped_packets, .Add, 1, .monotonic);
            return error.EgressSharedRingFull;
        }
    }

    /// Bytes written and not yet read, against the ring's capacity. Cursors
    /// that disagree mark the ring corrupt and fail with
    /// `error.InvalidEgressSharedRing`.
    pub fn usage(self: *const RingView) !Usage {
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        const read_seq = @atomicLoad(u64, &self.consumer.read_seq, .acquire);
        const write_seq = @atomicLoad(u64, &self.producer.write_seq, .acquire);
        if (write_seq < read_seq or write_seq - read_seq > self.capacity()) {
            @constCast(self).markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        return .{
            .used = @intCast(write_seq - read_seq),
            .capacity = self.capacity(),
        };
    }

    /// Copies the next packet into `out` and returns that prefix, or null when
    /// the ring is empty. A packet longer than `out` stays in the ring and
    /// fails with `error.EgressSharedScratchTooSmall`; cursors or a frame
    /// header that disagree mark the ring corrupt and fail with
    /// `error.InvalidEgressSharedRing`.
    pub fn readPacket(self: *RingView, out: []u8) !?[]u8 {
        if (!self.access.read_packets)
            return error.EgressSharedWrongSide;
        if (self.fatalState() != .none)
            return error.EgressSharedRingFatal;
        const ring_capacity = self.capacity();
        const read_seq = @atomicLoad(u64, &self.consumer.read_seq, .monotonic);
        const write_seq = @atomicLoad(u64, &self.producer.write_seq, .acquire);
        if (write_seq < read_seq or write_seq - read_seq > ring_capacity) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        if (read_seq == write_seq)
            return null;

        var header: FrameHeader = undefined;
        const offset: usize = @intCast(read_seq % ring_capacity);
        self.copyOut(offset, std.mem.asBytes(&header));
        if (header.flags != 0 or header.len == 0 or header.len > max_packet_bytes) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        const record_len = checkedRecordLen(header.len) catch {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        };
        if (record_len > write_seq - read_seq) {
            self.markFatal(.ring_corrupt);
            return error.InvalidEgressSharedRing;
        }
        if (header.len > out.len)
            return error.EgressSharedScratchTooSmall;

        self.copyOut((offset + frame_header_size) % ring_capacity, out[0..header.len]);
        @atomicStore(u64, &self.consumer.read_seq, read_seq + @as(u64, @intCast(record_len)), .release);
        return out[0..header.len];
    }

    /// Reads up to `max_packets` packets into `out` and passes each to
    /// `handler`, valid only during that call; returns how many it read. A
    /// handler error stops the drain with its packet already consumed.
    pub fn drainAvailable(self: *RingView, out: []u8, comptime max_packets: usize, handler: anytype) !usize {
        var count: usize = 0;
        while (count < max_packets) {
            const packet = try self.readPacket(out) orelse break;
            try handler(packet);
            count += 1;
        }
        return count;
    }

    fn capacity(self: *const RingView) usize {
        return self.capacity_bytes;
    }

    fn data(self: *RingView) []u8 {
        return self.data_bytes[0..self.capacity()];
    }

    fn copyInto(self: *RingView, offset: usize, payload: []const u8) void {
        const ring = self.data();
        const first_len = @min(payload.len, ring.len - offset);
        @memcpy(ring[offset..][0..first_len], payload[0..first_len]);
        if (first_len < payload.len)
            @memcpy(ring[0..][0 .. payload.len - first_len], payload[first_len..]);
    }

    fn copyOut(self: *RingView, offset: usize, out: []u8) void {
        const ring = self.data();
        const first_len = @min(out.len, ring.len - offset);
        @memcpy(out[0..first_len], ring[offset..][0..first_len]);
        if (first_len < out.len)
            @memcpy(out[first_len..], ring[0..][0 .. out.len - first_len]);
    }
};

fn checkedRecordLen(packet_len: usize) !usize {
    return std.math.add(usize, frame_header_size, packet_len) catch error.Overflow;
}

pub const RingAccess = struct {
    read_packets: bool = false,
    write_packets: bool = false,
    write_session: bool = false,
};
