//! Covers the host reader (`dispatch.readResponse`) on its own socket: it
//! grants a producer more than its first window of chunks
//! (`dispatch.ResponseReadCredit`), pumping it through
//! `ReadBudget.progress_fn`, and ends at the request's `request_done` with the
//! measures it carries; it takes a `request_done` that comes without a head,
//! and refuses a chunk past the window, a descriptor of another identity and
//! anything after the `request_done`. The peer here speaks IPC directly, and
//! `common-test` covers the window's arithmetic and the `request_done`
//! decoder; worker tests cover JavaScript responses. Runs in `host-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd = @import("collo_os").fd;
const dispatch = @import("collo_host").dispatch;
const identity: ipc.ingress_channel.RequestIdentity = .{ .request_id = 1, .request_generation = 1, .request_lane_id = 0, .request_slot = 0 };
const stream_id: u32 = 1;

/// What the producer's `request_done` reports, so the reader's copy can be
/// compared field by field.
const producer_done: ipc.ingress_channel.RequestDone = .{
    .status = .ok,
    .http_status = 200,
    .exec_ns = 11,
    .waiting_ns = 12,
    .io_ns = 13,
    .cpu_ns = 14,
    .client_served_bytes = 8,
};

const Producer = struct {
    control_fd: std.posix.fd_t,
    head_sent: bool = false,
    done_sent: bool = false,
    sent: u64 = 0,
    allowance: u64 = ipc.response_credit.window,

    fn progress(context: ?*anyopaque) anyerror!void {
        const self: *Producer = @ptrCast(@alignCast(context.?));
        if (self.done_sent)
            return;
        for (0..16) |_| {
            var polls = [_]std.posix.pollfd{.{ .fd = self.control_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&polls, 0) == 0)
                break;
            var scratch: [40]u8 = undefined;
            var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.control_fd, &scratch);
            defer packet.deinit();
            const grant = try ipc.response_credit.decode(&packet);
            try std.testing.expectEqual(identity.request_id, grant.request_id);
            self.allowance = @max(self.allowance, grant.grant_chunks_total);
        }
        var scratch: [256]u8 = undefined;
        if (!self.head_sent) {
            var head_scratch: [32]u8 = undefined;
            const payload = try ipc.ingress_channel.encodeResponseHeadInto(&head_scratch, 200, &.{});
            try ipc.ingress_channel.sendDescriptorPayload(
                self.control_fd,
                ipc.ingress_channel.Descriptor.responseHead(identity, stream_id, 0, @intCast(payload.len), 200, 0, false),
                payload,
                &scratch,
            );
            self.head_sent = true;
        }
        for (0..4) |_| {
            if (self.sent == 8 or self.sent == self.allowance)
                break;
            try ipc.ingress_channel.sendDescriptorPayload(
                self.control_fd,
                ipc.ingress_channel.Descriptor.responseChunk(identity, stream_id, 0, 1, self.sent + 1 == 8),
                "x",
                &scratch,
            );
            self.sent += 1;
        }
        if (self.sent != 8)
            return;
        try ipc.ingress_channel.sendRequestDone(self.control_fd, identity, stream_id, producer_done, &scratch);
        self.done_sent = true;
    }
};

fn budgetFor(producer: *Producer) dispatch.ReadBudget {
    return .{
        .wall_ms = 1000,
        .max_body_bytes = 32,
        .max_headers_bytes = 128,
        .progress_context = producer,
        .progress_fn = Producer.progress,
    };
}

test "a host response reader pumps and credits a producer beyond its initial four chunks and ends at its request_done" {
    const pair = try fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    var producer: Producer = .{ .control_fd = pair[1] };
    var response = try dispatch.readResponse(std.testing.allocator, .{ .control_fd = pair[0] }, 1, budgetFor(&producer));
    defer response.deinit();
    try std.testing.expectEqualStrings("xxxxxxxx", response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.ok, response.done.status);
    try std.testing.expectEqual(producer_done, response.done);
}

test "a request_done that comes without a head ends the read with the worker's status" {
    const pair = try fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    var done = producer_done;
    done.status = .internal_error;
    done.http_status = 0;
    var scratch: [256]u8 = undefined;
    try ipc.ingress_channel.sendRequestDone(pair[1], identity, stream_id, done, &scratch);

    var response = try dispatch.readResponse(std.testing.allocator, .{ .control_fd = pair[0] }, 1, .{
        .wall_ms = 1000,
        .max_body_bytes = 32,
        .max_headers_bytes = 128,
    });
    defer response.deinit();
    try std.testing.expectEqual(ipc.RequestDoneStatus.internal_error, response.done.status);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
}

test "the host reader refuses a request_done of another request, and a descriptor after the request_done in one packet" {
    var scratch: [512]u8 = undefined;
    {
        const pair = try fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
        defer std.posix.close(pair[0]);
        defer std.posix.close(pair[1]);
        var other = identity;
        other.request_id = 2;
        try ipc.ingress_channel.sendRequestDone(pair[1], other, stream_id, producer_done, &scratch);
        try std.testing.expectError(error.InvalidH2StreamIdentity, dispatch.readResponse(std.testing.allocator, .{ .control_fd = pair[0] }, 1, .{
            .wall_ms = 1000,
            .max_body_bytes = 32,
            .max_headers_bytes = 128,
        }));
    }
    {
        const pair = try fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
        defer std.posix.close(pair[0]);
        defer std.posix.close(pair[1]);
        // The worker sends nothing of a request after its `request_done`.
        const producer_payload = ipc.ingress_channel.encodeRequestDone(producer_done);
        const entries = [_]ipc.ingress_channel.BatchEntry{
            .{ .descriptor = ipc.ingress_channel.Descriptor.requestDone(identity, stream_id), .payload = std.mem.asBytes(&producer_payload) },
            .{ .descriptor = ipc.ingress_channel.Descriptor.responseEnd(identity, stream_id) },
        };
        try ipc.ingress_channel.sendDescriptorBatchPayloads(pair[1], &entries, &scratch);
        try std.testing.expectError(error.DescriptorAfterRequestDone, dispatch.readResponse(std.testing.allocator, .{ .control_fd = pair[0] }, 1, .{
            .wall_ms = 1000,
            .max_body_bytes = 32,
            .max_headers_bytes = 128,
        }));
    }
}

test "a worker that closes its end before its request_done fails the read" {
    const pair = try fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    std.posix.close(pair[1]);
    try std.testing.expectError(error.ControlPeerClosed, dispatch.readResponse(std.testing.allocator, .{ .control_fd = pair[0] }, 1, .{
        .wall_ms = 1000,
        .max_body_bytes = 32,
        .max_headers_bytes = 128,
    }));
}

test "the host reader refuses a chunk before the head, a chunk past the window and a descriptor of another identity" {
    var credit: dispatch.ResponseReadCredit = .{ .request_id = 1 };
    const chunk = ipc.ingress_channel.Descriptor.responseChunk(identity, 1, 0, 1, false);
    try std.testing.expectError(error.InvalidH2WorkerInboundDescriptor, credit.admit(chunk));
    try credit.admit(ipc.ingress_channel.Descriptor.responseHead(identity, 1, 0, 8, 200, 0, false));
    for (0..ipc.response_credit.window) |_|
        try credit.admit(chunk);
    try std.testing.expectError(error.ResponseCreditExceeded, credit.admit(chunk));
    credit.retire(1);
    try std.testing.expect(credit.pending);
    try std.testing.expectEqual(ipc.response_credit.window + 1, credit.identity.?.grant_chunks_total);
    try credit.admit(chunk);
    var stale = chunk;
    stale.request_generation += 1;
    try std.testing.expectError(error.InvalidH2StreamIdentity, credit.admit(stale));
}
