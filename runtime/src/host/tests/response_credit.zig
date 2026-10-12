//! Covers the host reader's response credit (`dispatch.ResponseReadCredit`):
//! it grants a producer more than its first window of chunks, pumping it
//! through `ReadBudget.progress_fn`, refuses a chunk past the window and a
//! descriptor of another identity. The peer here speaks IPC directly, and
//! `common-test` covers the window's arithmetic; worker tests cover
//! JavaScript responses. Runs in `host-test`.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd = @import("collo_os").fd;
const dispatch = @import("collo_host").dispatch;
const page_mod = @import("collo_worker_state").page;
const identity: ipc.ingress_channel.RequestIdentity = .{ .request_id = 1, .request_generation = 1, .request_lane_id = 0, .request_slot = 0 };

const Producer = struct {
    control_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    page: *page_mod.WorkerWriterView,
    head_sent: bool = false,
    completion_sent: bool = false,
    sent: u64 = 0,
    allowance: u64 = ipc.response_credit.window,

    fn progress(context: ?*anyopaque) anyerror!void {
        const self: *Producer = @ptrCast(@alignCast(context.?));
        if (self.completion_sent)
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
                ipc.ingress_channel.Descriptor.responseHead(identity, 1, 0, @intCast(payload.len), 200, 0, false),
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
                ipc.ingress_channel.Descriptor.responseChunk(identity, 1, 0, 1, self.sent + 1 == 8),
                "x",
                &scratch,
            );
            self.sent += 1;
        }
        if (self.sent != 8)
            return;
        try self.page.publishWorkerCompletion(.{
            .external_request_id = 1,
            .request_lane_id = 0,
            .request_slot = 0,
            .request_generation = 1,
            .worker_id = 1,
            .worker_generation = 1,
            .status = @intFromEnum(ipc.RequestDoneStatus.ok),
            .http_status = 200,
        });
        var wake: u64 = 1;
        try std.testing.expectEqual(@as(usize, 8), try std.posix.write(self.completion_eventfd, std.mem.asBytes(&wake)));
        self.completion_sent = true;
    }
};

test "a host response reader pumps and credits a producer beyond its initial four chunks" {
    const pair = try fd.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    const page_fd = try page_mod.createMemfd("host-response-credit");
    defer std.posix.close(page_fd);
    var page = try page_mod.mapReadWrite(page_fd);
    defer page.deinit();
    page.initializeCrashDefault();
    const eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(eventfd);
    var producer: Producer = .{ .control_fd = pair[1], .completion_eventfd = eventfd, .page = &page };
    var response = try dispatch.readResponse(std.testing.allocator, .{
        .control_fd = pair[0],
        .completion_eventfd = eventfd,
        .metrics = &page,
    }, 1, .{
        .wall_ms = 1000,
        .max_body_bytes = 32,
        .max_headers_bytes = 128,
        .progress_context = &producer,
        .progress_fn = Producer.progress,
    });
    defer response.deinit();
    try std.testing.expectEqualStrings("xxxxxxxx", response.body);
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
