//! Send-channel serialization stress.
//!
//! Any lane may take any slot of a worker, so two lane threads can send into
//! one worker's channel at once. Two of the channel's primitives are
//! single-producer by construction: the shared payload ring writer, whose
//! write cursor is a plain field of the one view the lanes share and moves
//! without a CAS, and the worker's dispatch scratch. `Record.send_mutex` is
//! the serialization contract that makes several producers safe. This test
//! drives two producers through that contract against one SEQPACKET pair and
//! one ring and fails on any frame or payload corruption, the damage an
//! unserialized second producer causes.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;

const ingress_channel = ipc.ingress_channel;

const frames_per_producer = 300;
// Above the inline threshold so every frame exercises the ring writer.
const body_len = ingress_channel.shared_payload_threshold + 257;

fn patternByte(request_id: u64, index: usize) u8 {
    return @truncate(request_id *% 31 +% index *% 7);
}

const Producer = struct {
    control_fd: std.posix.fd_t,
    ring: *ingress_channel.SharedPayloadView,
    send_mutex: *std.Thread.Mutex,
    /// Shared across producers, like Record.dispatch_send_scratch.
    worker_scratch: []u8,
    base_request_id: u64,
    err: ?anyerror = null,

    fn main(self: *Producer) void {
        self.run() catch |err| {
            self.err = err;
        };
    }

    fn run(self: *Producer) !void {
        var lane_scratch: [ipc.max_message_bytes]u8 = undefined;
        var body: [body_len]u8 = undefined;
        var sequence: usize = 0;
        while (sequence < frames_per_producer) : (sequence += 1) {
            const request_id = self.base_request_id + sequence;
            const identity = ingress_channel.RequestIdentity{
                .request_id = request_id,
                .request_generation = 1,
                .request_lane_id = @intCast(self.base_request_id % 1000),
                .request_slot = 1,
            };
            for (&body, 0..) |*byte, index|
                byte.* = patternByte(request_id, index);
            const descriptor = ingress_channel.Descriptor.requestBodyChunk(
                identity,
                @intCast(sequence + 1),
                0,
                @intCast(body.len),
                true,
            );
            // Even frames use the shared worker scratch and odd frames the
            // lane-local one. Both write the shared ring under the mutex, as
            // dispatches and body chunks do in production.
            const scratch: []u8 = if (sequence % 2 == 0) self.worker_scratch else &lane_scratch;
            while (true) {
                self.send_mutex.lock();
                const result = ingress_channel.sendDescriptorPayloadRequireRing(
                    self.control_fd,
                    descriptor,
                    &body,
                    scratch,
                    self.ring.writer(.server_to_worker),
                );
                self.send_mutex.unlock();
                result catch |err| switch (err) {
                    // Consumer is draining concurrently; yield until space.
                    error.IngressSharedPayloadRingFull => {
                        std.Thread.yield() catch {};
                        continue;
                    },
                    else => return err,
                };
                break;
            }
        }
    }
};

test "concurrent producers under the send mutex never corrupt the channel" {
    const pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const ring_fd = try ingress_channel.createSharedPayloadMemfd();
    defer std.posix.close(ring_fd);
    try fd_mod.requireSeals(ring_fd, fd_mod.memfd_size_seals);
    var producer_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .server);
    defer producer_ring.deinit();
    var consumer_ring = try ingress_channel.mapSharedPayloadReadWrite(ring_fd, .worker);
    defer consumer_ring.deinit();

    var send_mutex = std.Thread.Mutex{};
    var worker_scratch: [ipc.max_message_bytes]u8 = undefined;

    var lane_a = Producer{
        .control_fd = pair[0],
        .ring = &producer_ring,
        .send_mutex = &send_mutex,
        .worker_scratch = &worker_scratch,
        .base_request_id = 1_000,
    };
    var lane_b = Producer{
        .control_fd = pair[0],
        .ring = &producer_ring,
        .send_mutex = &send_mutex,
        .worker_scratch = &worker_scratch,
        .base_request_id = 2_000_000,
    };

    const thread_a = try std.Thread.spawn(.{}, Producer.main, .{&lane_a});
    const thread_b = try std.Thread.spawn(.{}, Producer.main, .{&lane_b});

    // Consume on this thread: every frame must decode and carry the payload
    // pattern seeded by its own request id, so producers that interleave
    // inside the scratch or the ring's write cursor fail here byte for byte.
    var recv_scratch: [ipc.max_message_bytes]u8 = undefined;
    var received_count: usize = 0;
    var per_producer = [2]usize{ 0, 0 };
    while (received_count < frames_per_producer * 2) : (received_count += 1) {
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, pair[1], &recv_scratch);
        var received = try ingress_channel.decodeReceivedPacketWithSharedPayload(
            std.testing.allocator,
            &packet,
            .{ .server_to_worker = &consumer_ring },
        );
        defer received.deinit();
        try std.testing.expectEqual(
            @intFromEnum(ingress_channel.Op.request_body_chunk),
            received.descriptor.op,
        );
        const request_id = received.descriptor.request_id;
        if (request_id >= 2_000_000) {
            per_producer[1] += 1;
        } else {
            try std.testing.expect(request_id >= 1_000);
            per_producer[0] += 1;
        }
        try std.testing.expectEqual(@as(usize, body_len), received.payload.len);
        for (received.payload, 0..) |byte, index|
            try std.testing.expectEqual(patternByte(request_id, index), byte);
    }

    thread_a.join();
    thread_b.join();
    try std.testing.expect(lane_a.err == null);
    try std.testing.expect(lane_b.err == null);
    try std.testing.expectEqual(@as(usize, frames_per_producer), per_producer[0]);
    try std.testing.expectEqual(@as(usize, frames_per_producer), per_producer[1]);
}
