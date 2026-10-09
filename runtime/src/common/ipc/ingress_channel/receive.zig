//! The receiving side, in both directions. The host decodes a worker's
//! response descriptors on the ingress lane that reads the worker, and the
//! worker decodes request descriptors on its event loop thread. A decoder
//! copies an inline payload into memory from the caller's allocator and
//! borrows a ring payload in place from the ring its direction names
//! (`SharedPayloadReaders`).
//!
//! A receiver takes ring payloads in descriptor order, because the decoder
//! checks every payload's position against where the previous one ended.
//! Most receivers release each payload (`Received.deinit`,
//! `ReceivedBatch.deinit`) before they decode the next of that direction, so
//! that position is the ring's read cursor. A receiver that hands payloads to
//! another consumer keeps decoding past them and accounts for the bytes
//! itself (`SharedPayloadHolds`): the read cursor moves only over the
//! answered prefix of what it decoded, in ring order. The worker is untrusted
//! and both sides map the memfd writable, so every offset and length read
//! from a packet is checked before it is used. A decode starts from the
//! reader's own read cursor, and each payload's check loads the writer's
//! cursor once (`payload_ring.zig`).

const std = @import("std");

const dispatch = @import("../dispatch.zig");
const messages = @import("../messages.zig");
const packet = @import("../packet.zig");

const BatchPacketHeader = @import("framing.zig").BatchPacketHeader;
const Descriptor = @import("framing.zig").Descriptor;
const Op = @import("framing.zig").Op;
const Packet = @import("framing.zig").Packet;
const batchPayloadOffset = @import("framing.zig").batchPayloadOffset;
const batch_magic = @import("framing.zig").batch_magic;
const decodeOp = @import("framing.zig").decodeOp;
const flags = @import("framing.zig").flags;
const max_batch_descriptors = @import("framing.zig").max_batch_descriptors;
const validateDescriptor = @import("framing.zig").validateDescriptor;
const SharedPayloadDirection = @import("payload_ring.zig").SharedPayloadDirection;
const SharedPayloadReadRelease = @import("payload_ring.zig").SharedPayloadReadRelease;
const SharedPayloadView = @import("payload_ring.zig").SharedPayloadView;
const SharedPayloadWriter = @import("payload_ring.zig").SharedPayloadWriter;
const shared_payload_ring_capacity = @import("payload_ring.zig").shared_payload_ring_capacity;
const shared_payload_ring_count = @import("payload_ring.zig").shared_payload_ring_count;
const shared_payload_threshold = @import("payload_ring.zig").shared_payload_threshold;

/// The rings a decoder may read, by direction, with the credit eventfd to
/// signal after each release. A ring descriptor whose direction has no view
/// fails with `error.IngressSharedPayloadUnavailable`.
pub const SharedPayloadReaders = struct {
    server_to_worker: ?*SharedPayloadView = null,
    worker_to_server: ?*SharedPayloadView = null,
    server_to_worker_credit_eventfd: std.posix.fd_t = -1,
    worker_to_server_credit_eventfd: std.posix.fd_t = -1,
    /// The account of a reader that holds `worker_to_server` payloads for
    /// another consumer. With it, decoding starts at its cursor, each
    /// borrowed payload carries its span (`Received.ring_span`), and the
    /// decoder releases nothing, on success or failure: the caller hands
    /// every span to the account in ring order. Without it, decoding starts
    /// at the ring's read cursor and the result releases the bytes.
    worker_to_server_holds: ?*const SharedPayloadHolds = null,

    fn holdsFor(self: SharedPayloadReaders, direction: SharedPayloadDirection) ?*const SharedPayloadHolds {
        return switch (direction) {
            .server_to_worker => null,
            .worker_to_server => self.worker_to_server_holds,
        };
    }

    /// Where the next payload of `reader`'s ring starts.
    fn startCursor(self: SharedPayloadReaders, reader: SharedPayloadWriter) u64 {
        if (self.holdsFor(reader.direction)) |holds| {
            if (holds.cursor()) |held_cursor|
                return held_cursor;
        }
        return reader.view.readCursor(reader.direction);
    }

    fn forDescriptor(self: SharedPayloadReaders, descriptor: Descriptor) ?SharedPayloadWriter {
        return switch (@as(Op, @enumFromInt(descriptor.op))) {
            .request_body_chunk => if (self.server_to_worker) |view| .{
                .view = view,
                .direction = .server_to_worker,
                .credit_eventfd = self.server_to_worker_credit_eventfd,
            } else null,
            .response_chunk => if (self.worker_to_server) |view| .{
                .view = view,
                .direction = .worker_to_server,
                .credit_eventfd = self.worker_to_server_credit_eventfd,
            } else null,
            else => null,
        };
    }
};

/// A ring payload a decoder borrowed: where its descriptor put it, and the
/// ring bytes it reserves, a skipped tail included, which end at
/// `end_cursor`, where the next payload of its direction starts.
pub const SharedPayloadSpan = struct {
    offset: u64,
    len: u32,
    reserved_len: u64,
    end_cursor: u64,
};

/// The account of a reader that hands ring payloads to another consumer and
/// keeps decoding past them. It lists the payloads held for an answer, oldest
/// first, each with the reserved bytes of the payloads decoded after it that
/// need no answer or have one already, since those leave the ring with it.
/// The ring's read cursor therefore moves only over the answered prefix of
/// what the reader decoded, in ring order. Plain data on the reader's thread;
/// the reader releases the bytes each call returns
/// (`SharedPayloadReadRelease`).
pub const SharedPayloadHolds = struct {
    entries: [capacity]Entry = undefined,
    len: u8 = 0,
    /// The end of the last reservation accounted for, where the next payload
    /// starts; null before the first.
    end_cursor: ?u64 = null,

    /// Payloads a reader holds at most. A writer puts in a ring only payloads
    /// above `shared_payload_threshold`, so fewer than this fit in it at once,
    /// and a writer that leaves more held breaks the protocol.
    pub const capacity: usize = shared_payload_ring_capacity / shared_payload_threshold;

    const Entry = struct {
        offset: u64,
        len: u32,
        reserved_len: u64,
        /// Reserved bytes of later payloads that leave the ring with this one.
        trailing_len: u64,
    };

    comptime {
        std.debug.assert(capacity >= 1);
        std.debug.assert(capacity <= std.math.maxInt(u8));
    }

    /// Where the next payload starts, or null before the first one accounted
    /// for, when the ring's read cursor tells.
    pub fn cursor(self: *const SharedPayloadHolds) ?u64 {
        return self.end_cursor;
    }

    pub fn isEmpty(self: *const SharedPayloadHolds) bool {
        return self.len == 0;
    }

    /// Holds `span`, the next payload in ring order, until `answer` names it.
    /// False, holding nothing, when `capacity` payloads are held already.
    pub fn hold(self: *SharedPayloadHolds, span: SharedPayloadSpan) bool {
        self.assertNext(span);
        if (self.len == capacity)
            return false;
        self.entries[self.len] = .{
            .offset = span.offset,
            .len = span.len,
            .reserved_len = span.reserved_len,
            .trailing_len = 0,
        };
        self.len += 1;
        self.end_cursor = span.end_cursor;
        return true;
    }

    /// Accounts for `span`, the next payload in ring order, whose consumer is
    /// done with it, and returns the ring bytes to release now: its whole
    /// reservation when nothing is held, and none otherwise, since it then
    /// leaves with the payload held before it.
    pub fn pass(self: *SharedPayloadHolds, span: SharedPayloadSpan) u64 {
        self.assertNext(span);
        self.end_cursor = span.end_cursor;
        if (self.len == 0)
            return span.reserved_len;
        self.entries[self.len - 1].trailing_len += span.reserved_len;
        return 0;
    }

    /// Answers the oldest held payload at `offset` of `len` bytes and returns
    /// the ring bytes to release now: the answered prefix when it was the
    /// oldest held, none while an older one waits, and null when no held
    /// payload matches.
    pub fn answer(self: *SharedPayloadHolds, offset: u64, len: u32) ?u64 {
        const index = for (self.entries[0..self.len], 0..) |entry, entry_index| {
            if (entry.offset == offset and entry.len == len)
                break entry_index;
        } else return null;
        const freed = self.entries[index].reserved_len + self.entries[index].trailing_len;
        std.mem.copyForwards(Entry, self.entries[index .. self.len - 1], self.entries[index + 1 .. self.len]);
        self.len -= 1;
        if (index == 0)
            return freed;
        self.entries[index - 1].trailing_len += freed;
        return 0;
    }

    /// Forgets every payload without releasing any, for a reader that stops
    /// reading the ring.
    pub fn clear(self: *SharedPayloadHolds) void {
        self.* = .{};
    }

    /// The caller decodes with this account's cursor and accounts for every
    /// span in ring order, so each one starts where the last one ended.
    fn assertNext(self: *const SharedPayloadHolds, span: SharedPayloadSpan) void {
        if (self.end_cursor) |end_cursor|
            std.debug.assert(span.end_cursor -% span.reserved_len == end_cursor);
    }
};

/// One decoded descriptor. Its payload is a copy from `allocator` when
/// `payload_owned`, or else borrowed ring bytes that stay valid until
/// `deinit` releases them, until the batch it came from is released, or,
/// when the reader keeps its own account (`SharedPayloadHolds`), until that
/// account releases them.
pub const Received = struct {
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    payload: []u8 = &.{},
    payload_owned: bool = true,
    shared_release: SharedPayloadReadRelease = .{},
    /// Where a borrowed ring payload sits and what it reserves; null for any
    /// other payload, an empty one included.
    ring_span: ?SharedPayloadSpan = null,

    pub fn deinit(self: *Received) void {
        if (self.payload_owned and self.payload.len != 0)
            self.allocator.free(self.payload);
        self.shared_release.release();
        self.* = undefined;
    }
};

/// The decoded descriptors of one batch. The batch holds the ring bytes of
/// every item, one release per direction, and frees them on `deinit`.
pub const ReceivedBatch = struct {
    allocator: std.mem.Allocator,
    items: []Received,
    shared_releases: [shared_payload_ring_count]SharedPayloadReadRelease = [_]SharedPayloadReadRelease{.{}} ** shared_payload_ring_count,

    pub fn deinit(self: *ReceivedBatch) void {
        for (self.items) |*item|
            item.deinit();
        for (&self.shared_releases) |*release|
            release.release();
        self.allocator.free(self.items);
        self.* = undefined;
    }

    /// Moves item `index` to the caller and leaves an empty item in its
    /// place. A borrowed payload in the moved item stays valid only until
    /// this batch is released.
    pub fn take(self: *ReceivedBatch, index: usize) Received {
        std.debug.assert(index < self.items.len);
        const out = self.items[index];
        self.items[index] = .{
            .allocator = self.allocator,
            .descriptor = out.descriptor,
            .payload_owned = false,
        };
        return out;
    }
};

/// Whether `bytes` is a batch rather than a single packet.
pub fn isDescriptorBatchPacket(bytes: []const u8) bool {
    if (bytes.len < @sizeOf(BatchPacketHeader))
        return false;
    const kind = packet.readStruct(u32, bytes[0..@sizeOf(u32)]);
    if ((messages.decodeMessageKind(kind) catch return false) != .ingress_channel)
        return false;
    const magic_offset = @offsetOf(BatchPacketHeader, "magic");
    const magic = packet.readStruct(u32, bytes[magic_offset..][0..@sizeOf(u32)]);
    return magic == batch_magic;
}

/// Decodes a single packet that carries no payload.
pub fn decodeDescriptor(bytes: []const u8) !Descriptor {
    const decoded = try decodePacketView(bytes);
    if (decoded.payload.len != 0)
        return error.InvalidPacket;
    return decoded.descriptor;
}

/// The first descriptor of a packet that failed to decode, to name the
/// stream an error belongs to. Only the kind, the reserved fields and the
/// operation are checked, so nothing else in it may be trusted.
pub fn peekDescriptorForError(bytes: []const u8) !Descriptor {
    if (isDescriptorBatchPacket(bytes))
        return peekBatchDescriptorForError(bytes);
    if (bytes.len < @sizeOf(Packet))
        return error.InvalidPacket;
    const decoded = packet.readStruct(Packet, bytes[0..@sizeOf(Packet)]);
    if (try messages.decodeMessageKind(decoded.kind) != .ingress_channel)
        return error.InvalidMessageKind;
    if (decoded.reserved0 != 0)
        return error.InvalidPacket;
    _ = try decodeOp(decoded.descriptor.op);
    return decoded.descriptor;
}

fn peekBatchDescriptorForError(bytes: []const u8) !Descriptor {
    if (bytes.len < @sizeOf(BatchPacketHeader) + @sizeOf(Descriptor))
        return error.InvalidPacket;
    const header = packet.readStruct(BatchPacketHeader, bytes[0..@sizeOf(BatchPacketHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .ingress_channel)
        return error.InvalidMessageKind;
    if (header.magic != batch_magic or header.reserved0 != 0 or header.descriptor_count == 0)
        return error.InvalidPacket;
    const descriptor = packet.readStruct(
        Descriptor,
        bytes[@sizeOf(BatchPacketHeader)..][0..@sizeOf(Descriptor)],
    );
    _ = try decodeOp(descriptor.op);
    return descriptor;
}

/// Decodes a single packet when no ring is mapped, copying an inline payload
/// into memory from `allocator`; a ring descriptor fails with
/// `error.InvalidPacket`, and so does a packet that carried a file
/// descriptor. Consumes `received_packet` on every path.
pub fn decodeReceivedPacket(allocator: std.mem.Allocator, received_packet: *packet.ReceivedPacket) !Received {
    defer received_packet.deinit();
    if (received_packet.fd_count != 0)
        return error.InvalidPacket;
    const decoded = try decodePacketView(received_packet.bytes);
    const descriptor = decoded.descriptor;
    var owned_payload: []u8 = &.{};

    if (descriptor.hasFlag(flags.inline_bytes)) {
        if (decoded.payload.len != 0)
            owned_payload = try allocator.dupe(u8, decoded.payload);
    } else if (descriptor.byte_len != 0) {
        return error.InvalidPacket;
    }

    return .{
        .allocator = allocator,
        .descriptor = descriptor,
        .payload = owned_payload,
    };
}

/// As `decodeReceivedPacket`, except that a ring payload in one of `readers`
/// is borrowed instead of copied: the result reads as an inline descriptor
/// and carries the payload's `ring_span`. It releases the ring bytes on
/// `deinit`, unless `readers` holds the account of that direction, which
/// then owns the release. Without an account, the previous ring payload of
/// that direction must already be released.
pub fn decodeReceivedPacketWithSharedPayload(
    allocator: std.mem.Allocator,
    received_packet: *packet.ReceivedPacket,
    readers: SharedPayloadReaders,
) !Received {
    defer received_packet.deinit();
    if (received_packet.fd_count != 0)
        return error.InvalidPacket;
    const decoded = try decodePacketView(received_packet.bytes);
    var descriptor = decoded.descriptor;
    var owned_payload: []u8 = &.{};
    var payload_owned = true;
    var shared_release: SharedPayloadReadRelease = .{};
    var ring_span: ?SharedPayloadSpan = null;
    errdefer shared_release.release();
    errdefer if (payload_owned and owned_payload.len != 0) allocator.free(owned_payload);

    if (descriptor.hasFlag(flags.inline_bytes)) {
        if (decoded.payload.len != 0)
            owned_payload = try allocator.dupe(u8, decoded.payload);
    } else if (descriptor.hasFlag(flags.shared_ring)) {
        const reader = readers.forDescriptor(descriptor) orelse return error.IngressSharedPayloadUnavailable;
        const read_cursor = readers.startCursor(reader);
        const borrowed = try reader.view.readBorrowAt(
            reader.direction,
            read_cursor,
            descriptor.shared_offset,
            descriptor.byte_len,
        );
        owned_payload = borrowed.bytes;
        payload_owned = false;
        if (borrowed.reserved_len != 0) {
            ring_span = .{
                .offset = descriptor.shared_offset,
                .len = descriptor.byte_len,
                .reserved_len = borrowed.reserved_len,
                .end_cursor = read_cursor + borrowed.reserved_len,
            };
        }
        if (readers.holdsFor(reader.direction) == null) {
            shared_release = .{
                .view = reader.view,
                .direction = reader.direction,
                .byte_len = borrowed.reserved_len,
                .credit_eventfd = reader.credit_eventfd,
            };
        }
        descriptor.flag_bits &= ~flags.shared_ring;
        descriptor.flag_bits |= flags.inline_bytes;
        descriptor.shared_offset = 0;
        descriptor.byte_len = @intCast(owned_payload.len);
    } else if (descriptor.byte_len != 0) {
        return error.InvalidPacket;
    }

    return .{
        .allocator = allocator,
        .descriptor = descriptor,
        .payload = owned_payload,
        .payload_owned = payload_owned,
        .shared_release = shared_release,
        .ring_span = ring_span,
    };
}

/// As `decodeReceivedBatchPacketWithSharedPayload` with no ring mapped, so a
/// ring descriptor fails with `error.IngressSharedPayloadUnavailable`.
pub fn decodeReceivedBatchPacket(allocator: std.mem.Allocator, received_packet: *packet.ReceivedPacket) !ReceivedBatch {
    return decodeReceivedBatchPacketWithSharedPayload(allocator, received_packet, .{});
}

/// Decodes a batch into items allocated from `allocator`, copying inline
/// payloads and borrowing ring payloads, which must follow one another in
/// their ring; each borrowed item carries its `ring_span`. The batch
/// releases the ring bytes of all its items on `deinit`, except in a
/// direction whose account `readers` holds, which then owns the release.
/// Without an account, the previous ring payload of each direction must
/// already be released. A batch that carried a file descriptor fails with
/// `error.InvalidPacket`. Consumes `received_packet` on every path.
pub fn decodeReceivedBatchPacketWithSharedPayload(
    allocator: std.mem.Allocator,
    received_packet: *packet.ReceivedPacket,
    readers: SharedPayloadReaders,
) !ReceivedBatch {
    defer received_packet.deinit();
    if (received_packet.fd_count != 0)
        return error.InvalidPacket;
    const decoded = try decodeBatchView(received_packet.bytes);
    const items = try allocator.alloc(Received, decoded.descriptor_count);
    errdefer allocator.free(items);
    for (items) |*item| {
        item.* = .{
            .allocator = allocator,
            .descriptor = std.mem.zeroes(Descriptor),
        };
    }
    errdefer {
        for (items) |*item|
            item.deinit();
    }

    // Where the next ring payload of each direction starts.
    var next_cursors = [_]?u64{null} ** shared_payload_ring_count;
    var shared_releases = [_]SharedPayloadReadRelease{.{}} ** shared_payload_ring_count;
    errdefer {
        for (&shared_releases) |*release|
            release.release();
    }

    var index: usize = 0;
    while (index < decoded.descriptor_count) : (index += 1) {
        var descriptor = decoded.descriptorAt(index);
        var owned_payload: []u8 = &.{};
        var payload_owned = true;
        var ring_span: ?SharedPayloadSpan = null;
        if (descriptor.hasFlag(flags.inline_bytes)) {
            const payload = try decoded.inlinePayload(descriptor);
            owned_payload = if (payload.len == 0)
                &.{}
            else
                try allocator.dupe(u8, payload);
            descriptor.shared_offset = 0;
            descriptor.byte_len = @intCast(owned_payload.len);
        } else if (descriptor.hasFlag(flags.shared_ring)) {
            const reader = readers.forDescriptor(descriptor) orelse return error.IngressSharedPayloadUnavailable;
            const direction_index = @intFromEnum(reader.direction);
            const read_cursor = next_cursors[direction_index] orelse readers.startCursor(reader);
            const borrowed = try reader.view.readBorrowAt(
                reader.direction,
                read_cursor,
                descriptor.shared_offset,
                descriptor.byte_len,
            );
            // `readBorrowAt` checked that the reservation ends at or before
            // the write cursor, so this sum cannot overflow.
            next_cursors[direction_index] = read_cursor + borrowed.reserved_len;
            owned_payload = borrowed.bytes;
            payload_owned = false;
            if (borrowed.reserved_len != 0) {
                ring_span = .{
                    .offset = descriptor.shared_offset,
                    .len = descriptor.byte_len,
                    .reserved_len = borrowed.reserved_len,
                    .end_cursor = read_cursor + borrowed.reserved_len,
                };
            }
            if (readers.holdsFor(reader.direction) == null) {
                if (shared_releases[direction_index].view == null)
                    shared_releases[direction_index] = .{
                        .view = reader.view,
                        .direction = reader.direction,
                        .credit_eventfd = reader.credit_eventfd,
                    };
                shared_releases[direction_index].byte_len += borrowed.reserved_len;
            }
            descriptor.flag_bits &= ~flags.shared_ring;
            descriptor.flag_bits |= flags.inline_bytes;
            descriptor.shared_offset = 0;
            descriptor.byte_len = @intCast(owned_payload.len);
        } else if (descriptor.byte_len != 0) {
            return error.InvalidPacket;
        }

        items[index] = .{
            .allocator = allocator,
            .descriptor = descriptor,
            .payload = owned_payload,
            .payload_owned = payload_owned,
            .ring_span = ring_span,
        };
    }

    return .{
        .allocator = allocator,
        .items = items,
        .shared_releases = shared_releases,
    };
}

/// Decodes the DispatchWork a request begin carries inline.
pub fn decodeDispatchPayload(allocator: std.mem.Allocator, received: *Received) !dispatch.DispatchWork {
    if (received.descriptor.op != @intFromEnum(Op.request_begin))
        return error.InvalidPacket;
    if (!received.descriptor.hasFlag(flags.inline_bytes))
        return error.InvalidPacket;
    return dispatch.decodeDispatchWork(allocator, received.payload);
}

const PacketView = struct {
    descriptor: Descriptor,
    payload: []const u8,
};

const BatchView = struct {
    bytes: []const u8,
    descriptor_count: usize,
    descriptors_start: usize,
    payload_start: usize,
    payload: []const u8,

    fn descriptorAt(self: BatchView, index: usize) Descriptor {
        std.debug.assert(index < self.descriptor_count);
        const offset = self.descriptors_start + index * @sizeOf(Descriptor);
        return packet.readStruct(Descriptor, self.bytes[offset..][0..@sizeOf(Descriptor)]);
    }

    fn inlinePayload(self: BatchView, descriptor: Descriptor) ![]const u8 {
        const start: usize = @intCast(descriptor.shared_offset);
        const len: usize = @intCast(descriptor.byte_len);
        const end = std.math.add(usize, start, len) catch return error.InvalidPacket;
        if (end > self.payload.len)
            return error.InvalidPacket;
        return self.payload[start..end];
    }
};

fn decodePacketView(bytes: []const u8) !PacketView {
    if (bytes.len < @sizeOf(Packet))
        return error.InvalidPacket;
    const decoded = packet.readStruct(Packet, bytes);
    if (try messages.decodeMessageKind(decoded.kind) != .ingress_channel)
        return error.InvalidMessageKind;
    if (decoded.reserved0 != 0)
        return error.InvalidPacket;
    try validateDescriptor(decoded.descriptor);
    const payload = bytes[@sizeOf(Packet)..];
    if (decoded.descriptor.hasFlag(flags.inline_bytes)) {
        if (payload.len != decoded.descriptor.byte_len)
            return error.InvalidPacket;
    } else if (payload.len != 0) {
        return error.InvalidPacket;
    }
    return .{ .descriptor = decoded.descriptor, .payload = payload };
}

fn decodeBatchView(bytes: []const u8) !BatchView {
    if (bytes.len < @sizeOf(BatchPacketHeader))
        return error.InvalidPacket;
    const header = packet.readStruct(BatchPacketHeader, bytes[0..@sizeOf(BatchPacketHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .ingress_channel)
        return error.InvalidMessageKind;
    if (header.magic != batch_magic or header.reserved0 != 0)
        return error.InvalidPacket;
    if (header.descriptor_count == 0 or header.descriptor_count > max_batch_descriptors)
        return error.InvalidPacket;
    const descriptor_count: usize = header.descriptor_count;
    const payload_start = try batchPayloadOffset(descriptor_count);
    const total_len = std.math.add(usize, payload_start, header.payload_bytes_len) catch return error.InvalidPacket;
    if (total_len != bytes.len)
        return error.InvalidPacket;
    var index: usize = 0;
    while (index < descriptor_count) : (index += 1) {
        const offset = @sizeOf(BatchPacketHeader) + index * @sizeOf(Descriptor);
        const descriptor = packet.readStruct(Descriptor, bytes[offset..][0..@sizeOf(Descriptor)]);
        try validateDescriptor(descriptor);
        if (descriptor.hasFlag(flags.inline_bytes)) {
            const start: usize = @intCast(descriptor.shared_offset);
            const len: usize = @intCast(descriptor.byte_len);
            const end = std.math.add(usize, start, len) catch return error.InvalidPacket;
            if (end > header.payload_bytes_len)
                return error.InvalidPacket;
        } else if (descriptor.byte_len != 0 and !descriptor.hasFlag(flags.shared_ring)) {
            return error.InvalidPacket;
        }
    }
    return .{
        .bytes = bytes,
        .descriptor_count = descriptor_count,
        .descriptors_start = @sizeOf(BatchPacketHeader),
        .payload_start = payload_start,
        .payload = bytes[payload_start..],
    };
}
