//! The sending side, in both directions. The host sends request begins,
//! request body chunks and resets on an ingress lane's thread, and the worker
//! sends response heads, chunks, ends and resets on its event loop thread. A
//! chunk payload above `shared_payload_threshold` goes through the payload
//! ring of its direction and a smaller one rides inline, except where a
//! function says otherwise. A ring payload is published before the packet
//! that names it is sent, and when the packet is not sent its bytes are taken
//! back from the ring. A receiver expects ring payloads in descriptor order,
//! so two senders to one worker hold one lock across the ring write and the
//! send, as the server's lanes do with `Record.send_mutex` in
//! `server/supervisor/worker_table.zig`.

const std = @import("std");

const messages = @import("../messages.zig");
const packet = @import("../packet.zig");

const BatchPacketHeader = @import("framing.zig").BatchPacketHeader;
const Descriptor = @import("framing.zig").Descriptor;
const Packet = @import("framing.zig").Packet;
const batchPayloadOffset = @import("framing.zig").batchPayloadOffset;
const descriptorCanUseSharedRing = @import("framing.zig").descriptorCanUseSharedRing;
const flags = @import("framing.zig").flags;
const max_batch_descriptors = @import("framing.zig").max_batch_descriptors;
const validateDescriptor = @import("framing.zig").validateDescriptor;
const SharedPayloadWriter = @import("payload_ring.zig").SharedPayloadWriter;
const shared_payload_ring_capacity = @import("payload_ring.zig").shared_payload_ring_capacity;
const shared_payload_threshold = @import("payload_ring.zig").shared_payload_threshold;

/// One descriptor of a batch to send and its payload, which the encoder
/// places.
pub const BatchEntry = struct {
    descriptor: Descriptor,
    payload: []const u8 = &.{},
};

/// Sends `descriptor` alone, encoded in `scratch`.
pub fn sendDescriptor(control_fd: std.posix.fd_t, descriptor: Descriptor, scratch: []u8) !void {
    const encoded = try encodeDescriptorInto(scratch, descriptor);
    try packet.sendWithFds(control_fd, encoded, &.{});
}

/// Sends `descriptor` with `payload` inline, encoded in `scratch`.
pub fn sendDescriptorPayload(
    control_fd: std.posix.fd_t,
    descriptor: Descriptor,
    payload: []const u8,
    scratch: []u8,
) !void {
    const encoded = try encodeDescriptorPayloadInto(scratch, descriptor, payload);
    try packet.sendWithFds(control_fd, encoded, &.{});
}

/// Sends `entries` as one batch with their payloads inline, as
/// `encodeDescriptorBatchPayloadsInto` places them.
pub fn sendDescriptorBatchPayloads(control_fd: std.posix.fd_t, entries: []const BatchEntry, scratch: []u8) !void {
    const encoded = try encodeDescriptorBatchPayloadsInto(scratch, entries);
    try packet.sendWithFds(control_fd, encoded, &.{});
}

/// Sends `entries` as one batch with every payload in the ring of
/// `shared_writer`, whatever its size; each entry must be a chunk with a
/// payload, or the call fails with `error.IngressSharedPayloadUnavailable` or
/// `error.IngressSharedPayloadTooLarge`. When the packet is not sent, the
/// ring bytes this call wrote are taken back.
pub fn sendDescriptorBatchRingPayloads(
    control_fd: std.posix.fd_t,
    entries: []const BatchEntry,
    scratch: []u8,
    shared_writer: SharedPayloadWriter,
) !void {
    if (entries.len == 0 or entries.len > max_batch_descriptors)
        return error.InvalidPacket;
    var encoded_entries: [max_batch_descriptors]BatchEntry = undefined;
    var committed_len: usize = 0;
    var packet_sent = false;
    defer if (!packet_sent)
        shared_writer.view.cancelLastWrite(shared_writer.direction, committed_len);

    for (entries, 0..) |entry, index| {
        if (!descriptorCanUseSharedRing(entry.descriptor))
            return error.IngressSharedPayloadUnavailable;
        if (entry.payload.len == 0 or entry.payload.len > shared_payload_ring_capacity)
            return error.IngressSharedPayloadTooLarge;
        var encoded_descriptor = entry.descriptor;
        encoded_descriptor.flag_bits &= ~flags.inline_bytes;
        encoded_descriptor.flag_bits |= flags.shared_ring;
        const reservation = try shared_writer.view.write(shared_writer.direction, entry.payload);
        encoded_descriptor.shared_offset = reservation.offset;
        committed_len = std.math.add(
            usize,
            committed_len,
            reservation.reserved_len,
        ) catch {
            shared_writer.view.cancelLastWrite(shared_writer.direction, reservation.reserved_len);
            return error.MessageTooLarge;
        };
        encoded_descriptor.byte_len = @intCast(entry.payload.len);
        encoded_entries[index] = .{ .descriptor = encoded_descriptor };
    }

    try sendDescriptorBatchPayloads(control_fd, encoded_entries[0..entries.len], scratch);
    packet_sent = true;
}

/// Sends `entries` as one batch, moving to the ring of `shared_writer` each
/// chunk payload above `shared_payload_threshold` or one that would overflow
/// the packet; the rest ride inline. When the packet is not sent, the ring
/// bytes this call wrote are taken back.
pub fn sendDescriptorBatchPayloadsWithRing(
    control_fd: std.posix.fd_t,
    entries: []const BatchEntry,
    scratch: []u8,
    shared_writer: SharedPayloadWriter,
) !void {
    if (entries.len == 0 or entries.len > max_batch_descriptors)
        return error.InvalidPacket;
    var encoded_entries: [max_batch_descriptors]BatchEntry = undefined;
    const payload_start = try batchPayloadOffset(entries.len);
    const packet_budget = @min(scratch.len, messages.max_message_bytes);
    const inline_payload_budget = if (packet_budget > payload_start) packet_budget - payload_start else 0;
    var inline_payload_len: usize = 0;
    var committed_len: usize = 0;
    var packet_sent = false;
    defer if (!packet_sent)
        shared_writer.view.cancelLastWrite(shared_writer.direction, committed_len);

    for (entries, 0..) |entry, index| {
        const can_use_ring = entry.payload.len != 0 and descriptorCanUseSharedRing(entry.descriptor);
        const inline_would_overflow = entry.payload.len > inline_payload_budget -| inline_payload_len;
        if (can_use_ring and (entry.payload.len > shared_payload_threshold or inline_would_overflow)) {
            if (entry.payload.len > shared_payload_ring_capacity)
                return error.IngressSharedPayloadTooLarge;
            var encoded_descriptor = entry.descriptor;
            encoded_descriptor.flag_bits &= ~flags.inline_bytes;
            encoded_descriptor.flag_bits |= flags.shared_ring;
            const reservation = try shared_writer.view.write(shared_writer.direction, entry.payload);
            encoded_descriptor.shared_offset = reservation.offset;
            committed_len = std.math.add(
                usize,
                committed_len,
                reservation.reserved_len,
            ) catch {
                shared_writer.view.cancelLastWrite(shared_writer.direction, reservation.reserved_len);
                return error.MessageTooLarge;
            };
            encoded_descriptor.byte_len = @intCast(entry.payload.len);
            encoded_entries[index] = .{ .descriptor = encoded_descriptor };
            continue;
        }

        inline_payload_len = std.math.add(usize, inline_payload_len, entry.payload.len) catch return error.MessageTooLarge;
        encoded_entries[index] = entry;
    }

    try sendDescriptorBatchPayloads(control_fd, encoded_entries[0..entries.len], scratch);
    packet_sent = true;
}

/// As `sendDescriptorPayloadMaybeSharedWithRing` without a ring.
pub fn sendDescriptorPayloadMaybeShared(
    control_fd: std.posix.fd_t,
    descriptor: Descriptor,
    payload: []const u8,
    scratch: []u8,
) !void {
    try sendDescriptorPayloadMaybeSharedWithRing(control_fd, descriptor, payload, scratch, null);
}

/// Sends a chunk payload above `shared_payload_threshold` through
/// `shared_writer` when the ring takes it; a payload at or below the
/// threshold rides inline. A payload above the threshold that no ring takes
/// fails with `error.IngressSharedPayloadUnavailable`.
pub fn sendDescriptorPayloadMaybeSharedWithRing(
    control_fd: std.posix.fd_t,
    descriptor: Descriptor,
    payload: []const u8,
    scratch: []u8,
    shared_writer: ?SharedPayloadWriter,
) !void {
    if (payload.len > shared_payload_threshold and shared_writer != null and descriptorCanUseSharedRing(descriptor)) {
        const ring_sent = blk: {
            sendDescriptorRingPayload(control_fd, descriptor, payload, scratch, shared_writer.?) catch |err| switch (err) {
                error.IngressSharedPayloadRingFull,
                error.IngressSharedPayloadTooLarge,
                => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        if (ring_sent)
            return;
    }
    if (payload.len > shared_payload_threshold)
        return error.IngressSharedPayloadUnavailable;
    try sendDescriptorPayload(control_fd, descriptor, payload, scratch);
}

/// Sends a payload at or below `shared_payload_threshold` inline, and a
/// larger one through the ring of `shared_writer`. Without a ring, or for a
/// descriptor that may not use one, the larger payload fails with
/// `error.IngressSharedPayloadUnavailable`, and a full ring fails with
/// `error.IngressSharedPayloadRingFull`, sending nothing, so the caller can
/// retry later.
pub fn sendDescriptorPayloadRequireRing(
    control_fd: std.posix.fd_t,
    descriptor: Descriptor,
    payload: []const u8,
    scratch: []u8,
    shared_writer: ?SharedPayloadWriter,
) !void {
    if (payload.len <= shared_payload_threshold) {
        try sendDescriptorPayload(control_fd, descriptor, payload, scratch);
        return;
    }
    if (!descriptorCanUseSharedRing(descriptor))
        return error.IngressSharedPayloadUnavailable;
    const writer = shared_writer orelse return error.IngressSharedPayloadUnavailable;
    try sendDescriptorRingPayload(control_fd, descriptor, payload, scratch, writer);
}

fn sendDescriptorRingPayload(
    control_fd: std.posix.fd_t,
    descriptor: Descriptor,
    payload: []const u8,
    scratch: []u8,
    shared_writer: SharedPayloadWriter,
) !void {
    if (payload.len > std.math.maxInt(u32))
        return error.MessageTooLarge;
    var encoded_descriptor = descriptor;
    encoded_descriptor.flag_bits &= ~flags.inline_bytes;
    encoded_descriptor.flag_bits |= flags.shared_ring;
    const reservation = try shared_writer.view.write(shared_writer.direction, payload);
    encoded_descriptor.shared_offset = reservation.offset;
    var payload_committed = false;
    defer if (!payload_committed)
        shared_writer.view.cancelLastWrite(shared_writer.direction, reservation.reserved_len);
    encoded_descriptor.byte_len = @intCast(payload.len);
    const encoded = try encodeDescriptorInto(scratch, encoded_descriptor);
    try packet.sendWithFds(control_fd, encoded, &.{});
    payload_committed = true;
}

pub fn encodeDescriptorInto(scratch: []u8, descriptor: Descriptor) ![]u8 {
    return encodeDescriptorPayloadInto(scratch, descriptor, "");
}

/// Encodes a single packet with `payload` inline into `scratch` and returns
/// that prefix. The payload may already sit at its place right after the
/// `Packet` in `scratch`, which saves the copy; any other overlap with
/// `scratch` fails with `error.InvalidPacket`. Fails with
/// `error.DispatchScratchTooSmall` when `scratch` is too short and with
/// `error.MessageTooLarge` above `messages.max_message_bytes`.
pub fn encodeDescriptorPayloadInto(scratch: []u8, descriptor: Descriptor, payload: []const u8) ![]u8 {
    if (scratch.len < @sizeOf(Packet))
        return error.DispatchScratchTooSmall;
    if (payload.len > std.math.maxInt(u32))
        return error.MessageTooLarge;
    const total_len = std.math.add(usize, @sizeOf(Packet), payload.len) catch return error.MessageTooLarge;
    if (total_len > scratch.len)
        return error.DispatchScratchTooSmall;
    if (total_len > messages.max_message_bytes)
        return error.MessageTooLarge;
    var encoded_descriptor = descriptor;
    if (payload.len != 0) {
        encoded_descriptor.flag_bits |= flags.inline_bytes;
        encoded_descriptor.shared_offset = 0;
        encoded_descriptor.byte_len = @intCast(payload.len);
    }
    const encoded = Packet.init(encoded_descriptor);
    _ = packet.writeStruct(scratch, &encoded);
    const payload_dest = scratch[@sizeOf(Packet)..][0..payload.len];
    if (payload_dest.ptr != payload.ptr) {
        if (slicesOverlap(scratch[0..total_len], payload))
            return error.InvalidPacket;
        @memcpy(payload_dest, payload);
    }
    return scratch[0..total_len];
}

/// Encodes `entries` as one batch into `scratch`, every nonempty payload
/// inline in entry order, and returns that prefix. An entry without a payload
/// may carry `flags.shared_ring` with its ring offset and length already set.
/// Payloads may already sit at their place in `scratch`; any other overlap
/// fails with `error.InvalidPacket`, as do an empty batch, one over
/// `max_batch_descriptors` and an entry whose flags disagree with its
/// payload. Size failures are those of `encodeDescriptorPayloadInto`.
pub fn encodeDescriptorBatchPayloadsInto(scratch: []u8, entries: []const BatchEntry) ![]u8 {
    if (entries.len == 0 or entries.len > max_batch_descriptors)
        return error.InvalidPacket;

    const payload_start = try batchPayloadOffset(entries.len);
    var payload_len: usize = 0;
    for (entries) |entry| {
        if (entry.payload.len > std.math.maxInt(u32))
            return error.MessageTooLarge;
        payload_len = std.math.add(usize, payload_len, entry.payload.len) catch return error.MessageTooLarge;
    }
    if (payload_len > std.math.maxInt(u32))
        return error.MessageTooLarge;
    const total_len = std.math.add(usize, payload_start, payload_len) catch return error.MessageTooLarge;
    if (total_len > scratch.len)
        return error.DispatchScratchTooSmall;
    if (total_len > messages.max_message_bytes)
        return error.MessageTooLarge;

    const header = BatchPacketHeader{
        .kind = @intFromEnum(messages.MessageKind.ingress_channel),
        .descriptor_count = @intCast(entries.len),
        .payload_bytes_len = @intCast(payload_len),
    };
    var cursor: usize = 0;
    cursor += packet.writeStruct(scratch[cursor..], &header);

    var payload_cursor: usize = 0;
    for (entries) |entry| {
        var encoded_descriptor = entry.descriptor;
        if (entry.payload.len != 0) {
            if (encoded_descriptor.hasFlag(flags.shared_ring))
                return error.InvalidPacket;
            encoded_descriptor.flag_bits |= flags.inline_bytes;
            encoded_descriptor.shared_offset = @intCast(payload_cursor);
            encoded_descriptor.byte_len = @intCast(entry.payload.len);
        } else if (encoded_descriptor.hasFlag(flags.inline_bytes)) {
            if (encoded_descriptor.byte_len != 0)
                return error.InvalidPacket;
            encoded_descriptor.shared_offset = 0;
        } else if (encoded_descriptor.byte_len != 0 and !encoded_descriptor.hasFlag(flags.shared_ring)) {
            return error.InvalidPacket;
        }
        try validateDescriptor(encoded_descriptor);
        cursor += packet.writeStruct(scratch[cursor..], &encoded_descriptor);
        payload_cursor += entry.payload.len;
    }

    cursor = payload_start;
    for (entries) |entry| {
        const dest = scratch[cursor..][0..entry.payload.len];
        if (dest.ptr != entry.payload.ptr) {
            if (slicesOverlap(scratch[0..total_len], entry.payload))
                return error.InvalidPacket;
            @memcpy(dest, entry.payload);
        }
        cursor += entry.payload.len;
    }
    return scratch[0..total_len];
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0)
        return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start < b_start + b.len and b_start < a_start + a.len;
}
