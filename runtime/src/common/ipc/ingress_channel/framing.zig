//! The packet format both directions share. A single packet is a `Packet`, a
//! message kind and one `Descriptor`, followed by its inline payload; a batch
//! is a `BatchPacketHeader`, up to `max_batch_descriptors` descriptors and
//! one payload area. Both carry `messages.MessageKind.ingress_channel`, and
//! a batch carries `batch_magic` where a single packet's `reserved0` must be
//! zero, which is how `isDescriptorBatchPacket` tells them apart. A
//! descriptor names its request by the host's identity and its stream, and
//! `validateDescriptor` is what every decoded descriptor must satisfy. The
//! comptime checks at the bottom pin the layout.

const std = @import("std");

const messages = @import("../messages.zig");

/// Value 7 names no operation, and `decodeOp` refuses it.
pub const Op = enum(u8) {
    request_begin = 1,
    request_body_chunk = 2,
    response_head = 3,
    response_chunk = 4,
    response_end = 5,
    request_reset = 6,
    response_reset = 8,
};

pub const flags = struct {
    /// The last descriptor of its stream in this direction.
    pub const end_stream: u8 = 1 << 0;
    /// The constructors set it on every request begin and response head.
    pub const end_headers: u8 = 1 << 1;
    /// The payload is in this packet: right after the descriptor in a single
    /// packet, or at `shared_offset` in a batch's payload area.
    pub const inline_bytes: u8 = 1 << 2;
    /// The payload is in the ring of the descriptor's direction at
    /// `shared_offset`. Only chunk operations may set it, never together with
    /// `inline_bytes`.
    pub const shared_ring: u8 = 1 << 3;
};

pub const batch_magic: u32 = 0x494e4731; // "ING1" in ASCII, most significant byte first.
pub const max_batch_descriptors: usize = 32;

/// One message of a request's streams.
pub const Descriptor = extern struct {
    /// An `Op`.
    op: u8,
    /// `flags`.
    flag_bits: u8,
    request_lane_id: u16,
    request_slot: u32,
    /// The client's HTTP/2 stream.
    stream_id: u32,
    reserved0: u32 = 0,
    request_id: u64,
    request_generation: u64,
    /// Where the payload starts: in the ring with `flags.shared_ring`, in a
    /// batch's payload area with `flags.inline_bytes`, and 0 in a single
    /// packet.
    shared_offset: u64,
    byte_len: u32,
    /// The request begin's header count, the response head's status in the
    /// high 16 bits and header count in the low 16, or a reset's error code.
    aux: u32,

    pub fn requestBegin(identity: RequestIdentity, stream_id: u32, header_offset: u64, header_len: u32, header_count: u32, end_stream: bool) Descriptor {
        return init(.request_begin, identity, stream_id, header_offset, header_len, header_count, if (end_stream) flags.end_stream | flags.end_headers else flags.end_headers);
    }

    pub fn requestBodyChunk(identity: RequestIdentity, stream_id: u32, offset: u64, len: u32, end_stream: bool) Descriptor {
        return init(.request_body_chunk, identity, stream_id, offset, len, 0, if (end_stream) flags.end_stream else 0);
    }

    pub fn responseHead(identity: RequestIdentity, stream_id: u32, header_offset: u64, header_len: u32, status: u16, header_count: u16, end_stream: bool) Descriptor {
        const aux = (@as(u32, status) << 16) | header_count;
        return init(.response_head, identity, stream_id, header_offset, header_len, aux, if (end_stream) flags.end_stream | flags.end_headers else flags.end_headers);
    }

    pub fn responseChunk(identity: RequestIdentity, stream_id: u32, offset: u64, len: u32, end_stream: bool) Descriptor {
        return init(.response_chunk, identity, stream_id, offset, len, 0, if (end_stream) flags.end_stream else 0);
    }

    pub fn responseEnd(identity: RequestIdentity, stream_id: u32) Descriptor {
        return init(.response_end, identity, stream_id, 0, 0, 0, flags.end_stream);
    }

    pub fn requestReset(identity: RequestIdentity, stream_id: u32, error_code: u32) Descriptor {
        return init(.request_reset, identity, stream_id, 0, 0, error_code, 0);
    }

    pub fn responseReset(identity: RequestIdentity, stream_id: u32, error_code: u32) Descriptor {
        return init(.response_reset, identity, stream_id, 0, 0, error_code, 0);
    }

    pub fn hasFlag(self: Descriptor, flag: u8) bool {
        return (self.flag_bits & flag) != 0;
    }

    pub fn responseStatus(self: Descriptor) ?u16 {
        if (self.op != @intFromEnum(Op.response_head))
            return null;
        return @intCast(self.aux >> 16);
    }

    pub fn responseHeaderCount(self: Descriptor) ?u16 {
        if (self.op != @intFromEnum(Op.response_head))
            return null;
        return @intCast(self.aux & 0xffff);
    }

    fn init(op: Op, identity: RequestIdentity, stream_id: u32, offset: u64, len: u32, aux: u32, flag_bits: u8) Descriptor {
        return .{
            .op = @intFromEnum(op),
            .flag_bits = flag_bits,
            .request_lane_id = identity.request_lane_id,
            .request_slot = identity.request_slot,
            .stream_id = stream_id,
            .request_id = identity.request_id,
            .request_generation = identity.request_generation,
            .shared_offset = offset,
            .byte_len = len,
            .aux = aux,
        };
    }
};

/// The host's identity for a request, as its DispatchWork carries it
/// (`messages.DispatchWorkView`), repeated in every descriptor of the request.
pub const RequestIdentity = struct {
    request_id: u64,
    request_generation: u64,
    request_lane_id: u16,
    request_slot: u32,
};

/// A single-descriptor packet; an inline payload follows it.
pub const Packet = extern struct {
    kind: u32,
    reserved0: u32 = 0,
    descriptor: Descriptor,

    pub fn init(descriptor: Descriptor) Packet {
        return .{
            .kind = @intFromEnum(messages.MessageKind.ingress_channel),
            .descriptor = descriptor,
        };
    }
};

/// The head of a batch: `descriptor_count` descriptors follow it, then a
/// payload area of `payload_bytes_len` bytes.
pub const BatchPacketHeader = extern struct {
    kind: u32,
    magic: u32 = batch_magic,
    descriptor_count: u16,
    reserved0: u16 = 0,
    payload_bytes_len: u32,
};

/// Where the payload area of a batch of `descriptor_count` descriptors
/// starts, so a sender can build payloads in place.
pub fn batchPayloadOffset(descriptor_count: usize) !usize {
    if (descriptor_count == 0 or descriptor_count > max_batch_descriptors)
        return error.InvalidPacket;
    return std.math.add(usize, @sizeOf(BatchPacketHeader), descriptor_count * @sizeOf(Descriptor)) catch error.MessageTooLarge;
}

/// What every decoded descriptor must satisfy: a known operation, at most one
/// payload location, and the ring only for chunks.
pub fn validateDescriptor(descriptor: Descriptor) !void {
    _ = decodeOp(descriptor.op) catch return error.InvalidPacket;
    if (descriptor.hasFlag(flags.inline_bytes) and descriptor.hasFlag(flags.shared_ring))
        return error.InvalidPacket;
    if (descriptor.hasFlag(flags.shared_ring) and !descriptorCanUseSharedRing(descriptor))
        return error.InvalidPacket;
}

pub fn descriptorCanUseSharedRing(descriptor: Descriptor) bool {
    return descriptor.op == @intFromEnum(Op.request_body_chunk) or descriptor.op == @intFromEnum(Op.response_chunk);
}

pub fn decodeOp(raw: u8) !Op {
    return switch (raw) {
        @intFromEnum(Op.request_begin) => .request_begin,
        @intFromEnum(Op.request_body_chunk) => .request_body_chunk,
        @intFromEnum(Op.response_head) => .response_head,
        @intFromEnum(Op.response_chunk) => .response_chunk,
        @intFromEnum(Op.response_end) => .response_end,
        @intFromEnum(Op.request_reset) => .request_reset,
        @intFromEnum(Op.response_reset) => .response_reset,
        else => error.InvalidPacket,
    };
}

comptime {
    if (@sizeOf(Descriptor) != 48)
        @compileError("ipc.ingress_channel.Descriptor size mismatch");
    if (@alignOf(Descriptor) != 8)
        @compileError("ipc.ingress_channel.Descriptor alignment mismatch");
    if (@offsetOf(Descriptor, "op") != 0)
        @compileError("ipc.ingress_channel.Descriptor.op offset mismatch");
    if (@offsetOf(Descriptor, "stream_id") != 8)
        @compileError("ipc.ingress_channel.Descriptor.stream_id offset mismatch");
    if (@offsetOf(Descriptor, "request_id") != 16)
        @compileError("ipc.ingress_channel.Descriptor.request_id offset mismatch");
    if (@offsetOf(Descriptor, "shared_offset") != 32)
        @compileError("ipc.ingress_channel.Descriptor.shared_offset offset mismatch");
    if (@sizeOf(Packet) != 56)
        @compileError("ipc.ingress_channel.Packet size mismatch");
    if (@alignOf(Packet) != 8)
        @compileError("ipc.ingress_channel.Packet alignment mismatch");
    if (@offsetOf(Packet, "descriptor") != 8)
        @compileError("ipc.ingress_channel.Packet.descriptor offset mismatch");
    if (@sizeOf(BatchPacketHeader) != 16)
        @compileError("ipc.ingress_channel.BatchPacketHeader size mismatch");
    if (@offsetOf(BatchPacketHeader, "magic") != 4)
        @compileError("ipc.ingress_channel.BatchPacketHeader.magic offset mismatch");
}
