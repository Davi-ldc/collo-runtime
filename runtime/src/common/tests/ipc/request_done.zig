//! A request's `request_done` on the ingress channel
//! (`common/ipc/ingress_channel/framing.zig`): the value crossing alone and
//! as a batch entry, a batch encoded to end in one whose record is written
//! last (`send.zig:encodeBatchEndingInRequestDone`), the typed status only a
//! decode yields, and every
//! refusal of the decoders, which read the payload from an untrusted worker:
//! another length, a nonzero reserved byte or `aux`, an unknown status, an
//! HTTP status other than 0 or 100 through 599, and any flag but
//! `inline_bytes`. Packets cross an in-process SEQPACKET pair.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const ingress_channel = ipc.ingress_channel;
const Descriptor = ingress_channel.Descriptor;
const Packet = ingress_channel.Packet;
const RequestDone = ingress_channel.RequestDone;
const RequestDonePayload = ingress_channel.RequestDonePayload;

const identity = ingress_channel.RequestIdentity{
    .request_id = 41,
    .request_generation = 6,
    .request_lane_id = 2,
    .request_slot = 9,
};
const stream_id: u32 = 13;

/// A value with every measure set, so a field the codec drops shows.
const measured = RequestDone{
    .status = .js_exception,
    .http_status = 500,
    .exec_ns = 11,
    .waiting_ns = 12,
    .io_ns = 13,
    .cpu_ns = 14,
    .client_served_bytes = 15,
    .fetch_sent_bytes = 16,
    .fetch_received_bytes = 17,
};

/// `measured` as its payload crosses the socket.
const measured_payload = ingress_channel.encodeRequestDone(measured);

const Channel = struct {
    pair: [2]std.posix.fd_t,

    fn open() !Channel {
        return .{ .pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC) };
    }

    fn close(self: Channel) void {
        std.posix.close(self.pair[0]);
        std.posix.close(self.pair[1]);
    }

    /// Sends `bytes` as one packet and decodes it as a single packet.
    fn roundTrip(self: Channel, bytes: []const u8) !ingress_channel.Received {
        try ipc.packet.sendWithFds(self.pair[0], bytes, &.{});
        var scratch: [512]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.pair[1], &scratch);
        return ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
    }

    /// Sends `bytes` as one packet and decodes it as a batch.
    fn roundTripBatch(self: Channel, bytes: []const u8) !ingress_channel.ReceivedBatch {
        try ipc.packet.sendWithFds(self.pair[0], bytes, &.{});
        var scratch: [1024]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.pair[1], &scratch);
        return ingress_channel.decodeReceivedBatchPacket(std.testing.allocator, &packet);
    }

    /// Receives the next packet and decodes it as a single packet.
    fn receive(self: Channel) !ingress_channel.Received {
        var scratch: [256]u8 = undefined;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.pair[1], &scratch);
        return ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
    }
};

/// A single `request_done` packet carrying `payload`, encoded into `scratch`
/// without the sender's own check, so a test can send what the decoders
/// must refuse.
fn encodeSingle(scratch: []u8, descriptor: Descriptor, payload: []const u8) ![]u8 {
    return ingress_channel.encodeDescriptorPayloadInto(scratch, descriptor, payload);
}

/// Where field `name` of the payload sits in a single packet's bytes.
fn payloadOffset(comptime name: []const u8) usize {
    return @sizeOf(Packet) + @offsetOf(RequestDonePayload, name);
}

/// Where field `name` of the descriptor sits in a single packet's bytes.
fn descriptorOffset(comptime name: []const u8) usize {
    return @offsetOf(Packet, "descriptor") + @offsetOf(Descriptor, name);
}

fn expectRefusedSingle(channel: Channel, bytes: []const u8) !void {
    try std.testing.expectError(error.InvalidPacket, channel.roundTrip(bytes));
}

test "a request_done crosses alone and decodes to the value the worker sent" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [256]u8 = undefined;
    try ingress_channel.sendRequestDone(channel.pair[0], identity, stream_id, measured, &scratch);

    var received = try channel.receive();
    defer received.deinit();

    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_done), received.descriptor.op);
    try std.testing.expectEqual(ingress_channel.flags.inline_bytes, received.descriptor.flag_bits);
    try std.testing.expectEqual(identity.request_id, received.descriptor.request_id);
    try std.testing.expectEqual(identity.request_generation, received.descriptor.request_generation);
    try std.testing.expectEqual(identity.request_lane_id, received.descriptor.request_lane_id);
    try std.testing.expectEqual(identity.request_slot, received.descriptor.request_slot);
    try std.testing.expectEqual(stream_id, received.descriptor.stream_id);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&measured_payload), received.payload);
    try std.testing.expectEqual(measured, try ingress_channel.decodeRequestDone(received.payload));
}

test "the status of a request_done is typed only once decoded, and the wire keeps it a raw byte" {
    // The value a worker sends and a decode returns carries the enum, so no
    // reader converts the byte again and none can hold an unchecked one.
    try std.testing.expectEqual(ipc.RequestDoneStatus, @FieldType(RequestDone, "status"));
    try std.testing.expectEqual(u8, @FieldType(RequestDonePayload, "status"));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(RequestDonePayload));
    try std.testing.expectEqual(@intFromEnum(ipc.RequestDoneStatus.js_exception), measured_payload.status);
    try std.testing.expectEqual(@as(u8, 0), measured_payload.reserved0);
    try std.testing.expectEqual(@as(u32, 0), measured_payload.reserved1);
}

test "a request_done rides a batch after the response's end and decodes whole" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [512]u8 = undefined;
    const entries = [_]ingress_channel.BatchEntry{
        .{ .descriptor = Descriptor.responseEnd(identity, stream_id) },
        .{ .descriptor = Descriptor.requestDone(identity, stream_id), .payload = std.mem.asBytes(&measured_payload) },
    };
    const encoded = try ingress_channel.encodeDescriptorBatchPayloadsInto(&scratch, &entries);

    var batch = try channel.roundTripBatch(encoded);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch.items.len);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_end), batch.items[0].descriptor.op);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_done), batch.items[1].descriptor.op);
    try std.testing.expectEqual(measured, try ingress_channel.decodeRequestDone(batch.items[1].payload));
}

test "a batch encoded to end in a request_done takes its record after the rest and crosses whole" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [1024]u8 = undefined;
    const body = "the last bytes";
    const chunk = Descriptor.responseChunk(identity, stream_id, 0, body.len, true);
    const batch = try ingress_channel.encodeBatchEndingInRequestDone(&scratch, &.{
        .{ .descriptor = chunk, .payload = body },
    }, identity, stream_id, null);
    // The record is written once the rest of the batch is composed.
    try batch.setRequestDone(measured);
    try batch.send(channel.pair[0]);

    var packet_scratch: [1024]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, channel.pair[1], &packet_scratch);
    var received = try ingress_channel.decodeReceivedBatchPacket(std.testing.allocator, &packet);
    defer received.deinit();
    try std.testing.expectEqual(@as(usize, 2), received.items.len);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.response_chunk), received.items[0].descriptor.op);
    try std.testing.expectEqualStrings(body, received.items[0].payload);
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_done), received.items[1].descriptor.op);
    try std.testing.expectEqual(stream_id, received.items[1].descriptor.stream_id);
    try std.testing.expectEqual(measured, try ingress_channel.decodeRequestDone(received.items[1].payload));
}

test "a batch encoded to end in a request_done refuses a record the decoder would refuse, and a chunk that needs a ring it was given none for" {
    var scratch: [1024]u8 = undefined;
    const batch = try ingress_channel.encodeBatchEndingInRequestDone(&scratch, &.{
        .{ .descriptor = Descriptor.responseEnd(identity, stream_id) },
    }, identity, stream_id, null);
    const before = try std.testing.allocator.dupe(u8, batch.bytes);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(error.InvalidPacket, batch.setRequestDone(.{ .status = .ok, .http_status = 99 }));
    try std.testing.expectEqualSlices(u8, before, batch.bytes);

    const oversized = try std.testing.allocator.alloc(u8, ingress_channel.shared_payload_threshold + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    const large_scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(large_scratch);
    try std.testing.expectError(error.IngressSharedPayloadUnavailable, ingress_channel.encodeBatchEndingInRequestDone(large_scratch, &.{
        .{ .descriptor = Descriptor.responseChunk(identity, stream_id, 0, @intCast(oversized.len), true), .payload = oversized },
    }, identity, stream_id, null));
}

test "the item a batch's take leaves behind decodes to an error, never to a value" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [512]u8 = undefined;
    const encoded = try ingress_channel.encodeDescriptorBatchPayloadsInto(&scratch, &.{
        .{ .descriptor = Descriptor.requestDone(identity, stream_id), .payload = std.mem.asBytes(&measured_payload) },
    });
    var batch = try channel.roundTripBatch(encoded);
    defer batch.deinit();

    var taken = batch.take(0);
    defer taken.deinit();
    try std.testing.expectEqual(measured, try ingress_channel.decodeRequestDone(taken.payload));
    // The left item keeps the operation and loses the payload, so a reader
    // that decodes it gets the refusal it must handle.
    try std.testing.expectEqual(@intFromEnum(ingress_channel.Op.request_done), batch.items[0].descriptor.op);
    try std.testing.expectError(error.InvalidPacket, ingress_channel.decodeRequestDone(batch.items[0].payload));
}

test "every status the enum names crosses, and the HTTP status may be 0 or anything from 100 to 599" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [256]u8 = undefined;
    for (std.enums.values(ipc.RequestDoneStatus)) |status| {
        for ([_]u16{ 0, 100, 200, 599 }) |http_status| {
            var done = measured;
            done.status = status;
            done.http_status = http_status;
            try ingress_channel.sendRequestDone(channel.pair[0], identity, stream_id, done, &scratch);
            var received = try channel.receive();
            defer received.deinit();
            const read = try ingress_channel.decodeRequestDone(received.payload);
            try std.testing.expectEqual(status, read.status);
            try std.testing.expectEqual(http_status, read.http_status);
        }
    }
}

test "the decoders refuse a request_done whose payload is another length than RequestDonePayload" {
    const channel = try Channel.open();
    defer channel.close();

    var bytes: [@sizeOf(RequestDonePayload) + 1]u8 = undefined;
    @memcpy(bytes[0..@sizeOf(RequestDonePayload)], std.mem.asBytes(&measured_payload));
    bytes[@sizeOf(RequestDonePayload)] = 0;
    var scratch: [256]u8 = undefined;
    const descriptor = Descriptor.requestDone(identity, stream_id);
    try expectRefusedSingle(channel, try encodeSingle(&scratch, descriptor, bytes[0 .. @sizeOf(RequestDonePayload) - 1]));
    try expectRefusedSingle(channel, try encodeSingle(&scratch, descriptor, bytes[0 .. @sizeOf(RequestDonePayload) + 1]));
    // No payload at all.
    try expectRefusedSingle(channel, try encodeSingle(&scratch, descriptor, ""));

    // The batch encoder refuses to build one, and the batch decoder refuses
    // one built by hand: a valid batch whose entry's length is cut by one.
    var batch_scratch: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidPacket, ingress_channel.encodeDescriptorBatchPayloadsInto(&batch_scratch, &.{
        .{ .descriptor = descriptor, .payload = bytes[0 .. @sizeOf(RequestDonePayload) - 1] },
    }));
    const encoded = try ingress_channel.encodeDescriptorBatchPayloadsInto(&batch_scratch, &.{
        .{ .descriptor = descriptor, .payload = std.mem.asBytes(&measured_payload) },
    });
    // The batch's one descriptor ends where its payload area starts.
    const descriptor_at = (try ingress_channel.batchPayloadOffset(1)) - @sizeOf(Descriptor);
    const byte_len_at = descriptor_at + @offsetOf(Descriptor, "byte_len");
    std.mem.writeInt(u32, encoded[byte_len_at..][0..4], @sizeOf(RequestDonePayload) - 1, @import("builtin").cpu.arch.endian());
    try std.testing.expectError(error.InvalidPacket, channel.roundTripBatch(encoded));
}

test "the decoders refuse a request_done with a nonzero reserved byte" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [256]u8 = undefined;
    const descriptor = Descriptor.requestDone(identity, stream_id);
    for ([_]usize{ payloadOffset("reserved0"), payloadOffset("reserved1"), payloadOffset("reserved1") + 3 }) |at| {
        const encoded = try encodeSingle(&scratch, descriptor, std.mem.asBytes(&measured_payload));
        encoded[at] = 1;
        try expectRefusedSingle(channel, encoded);
    }

    // The same refusal inside a batch.
    var batch_scratch: [512]u8 = undefined;
    const encoded = try ingress_channel.encodeDescriptorBatchPayloadsInto(&batch_scratch, &.{
        .{ .descriptor = descriptor, .payload = std.mem.asBytes(&measured_payload) },
    });
    const payload_start = try ingress_channel.batchPayloadOffset(1);
    encoded[payload_start + @offsetOf(RequestDonePayload, "reserved0")] = 1;
    try std.testing.expectError(error.InvalidPacket, channel.roundTripBatch(encoded));
}

test "the decoders refuse a request_done whose status the enum does not name" {
    const channel = try Channel.open();
    defer channel.close();

    var last: u8 = 0;
    for (std.enums.values(ipc.RequestDoneStatus)) |status|
        last = @max(last, @intFromEnum(status));
    var scratch: [256]u8 = undefined;
    const descriptor = Descriptor.requestDone(identity, stream_id);
    for ([_]u8{ last + 1, std.math.maxInt(u8) }) |status| {
        var payload = measured_payload;
        payload.status = status;
        try expectRefusedSingle(channel, try encodeSingle(&scratch, descriptor, std.mem.asBytes(&payload)));
        try std.testing.expectError(error.InvalidPacket, ingress_channel.decodeRequestDone(std.mem.asBytes(&payload)));
        // The batch encoder checks a request_done's payload first and builds
        // nothing.
        var batch_scratch: [512]u8 = undefined;
        try std.testing.expectError(error.InvalidPacket, ingress_channel.encodeDescriptorBatchPayloadsInto(&batch_scratch, &.{
            .{ .descriptor = descriptor, .payload = std.mem.asBytes(&payload) },
        }));
    }
}

test "the decoders refuse a request_done whose HTTP status is neither 0 nor in 100 to 599" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [256]u8 = undefined;
    const descriptor = Descriptor.requestDone(identity, stream_id);
    for ([_]u16{ 1, 99, 600, std.math.maxInt(u16) }) |http_status| {
        var done = measured;
        done.http_status = http_status;
        const payload = ingress_channel.encodeRequestDone(done);
        try expectRefusedSingle(channel, try encodeSingle(&scratch, descriptor, std.mem.asBytes(&payload)));
        // The worker's sender checks the value first and sends nothing.
        try std.testing.expectError(
            error.InvalidPacket,
            ingress_channel.sendRequestDone(channel.pair[0], identity, stream_id, done, &scratch),
        );
    }
}

test "the decoders refuse a request_done with any flag but inline_bytes, or a nonzero aux" {
    const channel = try Channel.open();
    defer channel.close();

    var scratch: [256]u8 = undefined;
    const flags = ingress_channel.flags;
    // The encoder adds `inline_bytes` to whatever the descriptor carries.
    for ([_]u8{ flags.end_stream, flags.end_headers, flags.shared_ring, 1 << 7 }) |extra| {
        var descriptor = Descriptor.requestDone(identity, stream_id);
        descriptor.flag_bits = extra;
        try expectRefusedSingle(channel, try encodeSingle(&scratch, descriptor, std.mem.asBytes(&measured_payload)));
    }

    // Without `inline_bytes` the payload's bytes still follow the descriptor.
    const encoded = try encodeSingle(&scratch, Descriptor.requestDone(identity, stream_id), std.mem.asBytes(&measured_payload));
    encoded[descriptorOffset("flag_bits")] = 0;
    try expectRefusedSingle(channel, encoded);

    var with_aux = Descriptor.requestDone(identity, stream_id);
    with_aux.aux = 1;
    try expectRefusedSingle(channel, try encodeSingle(&scratch, with_aux, std.mem.asBytes(&measured_payload)));
}
