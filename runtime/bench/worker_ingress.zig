//! The ingress side of one worker request, played inside a bench process. It
//! encodes a DispatchWork as an ingress request-begin descriptor with inline
//! bytes, enqueues it straight into an in-process worker runtime that has
//! registered the request's route, and reads the response frames back from
//! the control socket. Everything runs on the caller's thread.
//!
//! The completion record on the shared metrics page is the only completion
//! channel, and no response frame follows it. The callers of `finishRequest`
//! in worker/serve/response.zig write the last frame before they call it, and
//! `finishRequest` (worker/serve/response_finish.zig) drops any response
//! still unsent before it publishes the record. A reader that sees the record
//! therefore drains the frames already pending on the control socket and
//! returns without waiting for more.

const std = @import("std");
const process = @import("collo_os").process;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const worker_shared_page = @import("collo_worker_state").page;
const bench_common = @import("common.zig");

const default_read_timeout_ns: u64 = 15 * std.time.ns_per_s;
// Longest single poll, so the read rechecks its deadline at least this often.
const max_poll_ms: u64 = 250;

pub const Response = struct {
    status: u16 = 200,
    /// The record the worker published on the shared metrics page when the
    /// request finished.
    completion: worker_shared_page.WorkerCompletionRecord = std.mem.zeroes(worker_shared_page.WorkerCompletionRecord),
    first_head_ns: u64 = 0,
    response_end_ns: u64 = 0,
    completion_ns: u64 = 0,
    headers_wire: []u8 = &.{},
    body: []u8 = &.{},

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.headers_wire.len != 0)
            allocator.free(self.headers_wire);
        if (self.body.len != 0)
            allocator.free(self.body);
        self.* = undefined;
    }
};

/// Completion side of the worker under measurement: metrics page writer view
/// plus the completion eventfd the runtime signals after each publish.
pub const CompletionChannels = struct {
    completion_eventfd: std.posix.fd_t,
    metrics: *worker_shared_page.WorkerWriterView,
};

pub const ReadOptions = struct {
    readers: ipc.ingress_channel.SharedPayloadReaders = .{},
    deadline_ns: ?u64 = null,
};

/// Hands `dispatch` to the in-process `runtime` as one request-begin
/// descriptor with a copy of its encoded bytes inline. The runtime must have
/// registered the route `dispatch` names. The caller keeps `dispatch`; the
/// runtime owns the copy from the call on, failure included.
pub fn enqueueRoute(
    allocator: std.mem.Allocator,
    runtime: *worker.Runtime,
    dispatch: *ipc.DispatchWork,
    stream_id: u32,
) !void {
    var payload_scratch: [ipc.max_message_bytes]u8 = undefined;
    var view = dispatch.view();
    const payload = try ipc.encodeDispatchWorkInto(&payload_scratch, &view);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = dispatch.request_id,
        .request_generation = dispatch.request_generation,
        .request_lane_id = dispatch.request_lane_id,
        .request_slot = dispatch.request_slot,
    };
    var descriptor = ipc.ingress_channel.Descriptor.requestBegin(
        identity,
        stream_id,
        0,
        @intCast(payload.len),
        @intCast(dispatch.request_headers.len),
        true,
    );
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;

    try runtime.enqueueIngressDescriptor(.{
        .allocator = allocator,
        .descriptor = descriptor,
        .payload = try allocator.dupe(u8, payload),
    });
}

/// `readResponseWithOptions` with the default options.
pub fn readResponse(
    allocator: std.mem.Allocator,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
    channels: CompletionChannels,
) !Response {
    return readResponseWithOptions(allocator, server_control_fd, request_id, channels, .{});
}

/// Reads response frames for `request_id` from `server_control_fd` until its
/// completion record appears on `channels.metrics`, then drains the frames
/// still pending. The caller owns the returned Response and frees it with
/// `deinit`. Fails with `error.BenchResponseTimeout` at `options.deadline_ns`,
/// or `default_read_timeout_ns` after the call when that is null; with
/// `error.UnexpectedCompletionRecord` when the next record belongs to another
/// request; and with `error.ResponseReset` when the worker resets the
/// response.
pub fn readResponseWithOptions(
    allocator: std.mem.Allocator,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
    channels: CompletionChannels,
    options: ReadOptions,
) !Response {
    var response = Response{};
    errdefer response.deinit(allocator);
    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(allocator);

    const deadline_ns = options.deadline_ns orelse try bench_common.deadlineFromNowNs(default_read_timeout_ns);
    while (true) {
        // The ring comes first because the record may already be published;
        // the eventfd is only a wakeup.
        var records: [1]worker_shared_page.WorkerCompletionRecord = undefined;
        const drained = try channels.metrics.drainWorkerCompletions(&records);
        if (drained != 0) {
            if (records[0].external_request_id != request_id)
                return error.UnexpectedCompletionRecord;
            response.completion = records[0];
            response.completion_ns = try process.monotonicNowNs();
            // Every frame was queued before the record, so the drain stops at
            // the first empty poll.
            while (true) {
                var control_poll = [1]std.posix.pollfd{.{
                    .fd = server_control_fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const control_ready = std.posix.poll(&control_poll, 0) catch 0;
                if (control_ready == 0 or (control_poll[0].revents & std.posix.POLL.IN) == 0)
                    break;
                try drainControlPacket(allocator, server_control_fd, &response, &body, options);
            }
            response.body = try body.toOwnedSlice(allocator);
            return response;
        }

        try waitEitherReadableBeforeDeadline(server_control_fd, channels.completion_eventfd, deadline_ns);
        var control_poll = [1]std.posix.pollfd{.{
            .fd = server_control_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const control_ready = std.posix.poll(&control_poll, 0) catch 0;
        if (control_ready != 0 and (control_poll[0].revents & std.posix.POLL.IN) != 0) {
            try drainControlPacket(allocator, server_control_fd, &response, &body, options);
            continue;
        }
        var counter_bytes: [8]u8 = undefined;
        _ = std.posix.read(channels.completion_eventfd, &counter_bytes) catch {};
    }
}

fn waitEitherReadableBeforeDeadline(
    control_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    deadline_ns: u64,
) !void {
    const now = try process.monotonicNowNs();
    if (now >= deadline_ns)
        return error.BenchResponseTimeout;
    const remaining_ns = deadline_ns - now;
    const remaining_ms = @max(
        @as(u64, 1),
        @min(max_poll_ms, (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms),
    );
    var pollfds = [2]std.posix.pollfd{
        .{
            .fd = control_fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
        .{
            .fd = completion_eventfd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    _ = try std.posix.poll(&pollfds, @intCast(remaining_ms));
    if (pollfds[0].revents & std.posix.POLL.ERR != 0)
        return error.PollError;
}

fn drainControlPacket(
    allocator: std.mem.Allocator,
    server_control_fd: std.posix.fd_t,
    response: *Response,
    body: *std.ArrayList(u8),
    options: ReadOptions,
) !void {
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(allocator, server_control_fd, &scratch);
    var packet_alive = true;
    defer if (packet_alive) packet.deinit();

    const kind = if (packet.bytes.len >= @sizeOf(u32))
        try ipc.decodeMessageKind(ipc.packet.readStruct(u32, packet.bytes[0..@sizeOf(u32)]))
    else
        return error.ShortRead;

    switch (kind) {
        .ingress_channel => {
            // The ingress decoders deinit the packet on every path, errors
            // included, so ownership moves to them before the decode.
            packet_alive = false;
            if (ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
                var batch = try ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload(allocator, &packet, options.readers);
                defer batch.deinit();
                for (batch.items) |item| {
                    try appendResponsePayload(allocator, response, body, item.descriptor, item.payload);
                }
            } else {
                var received = try ipc.ingress_channel.decodeReceivedPacketWithSharedPayload(allocator, &packet, options.readers);
                defer received.deinit();
                try appendResponsePayload(allocator, response, body, received.descriptor, received.payload);
            }
        },
        else => {
            packet.deinit();
            packet_alive = false;
            return error.InvalidMessageKind;
        },
    }
}

fn appendResponsePayload(
    allocator: std.mem.Allocator,
    response: *Response,
    body: *std.ArrayList(u8),
    descriptor: ipc.ingress_channel.Descriptor,
    payload: []const u8,
) !void {
    switch (descriptor.op) {
        @intFromEnum(ipc.ingress_channel.Op.response_head) => {
            var head = try ipc.ingress_channel.decodeResponseHead(allocator, payload);
            defer head.deinit();
            response.status = head.status;
            if (response.first_head_ns == 0)
                response.first_head_ns = try process.monotonicNowNs();
            if (response.headers_wire.len != 0) {
                allocator.free(response.headers_wire);
                response.headers_wire = &.{};
            }
            var wire = std.ArrayList(u8).empty;
            errdefer wire.deinit(allocator);
            for (head.headers) |header| {
                try wire.appendSlice(allocator, header.name);
                try wire.appendSlice(allocator, ": ");
                try wire.appendSlice(allocator, header.value);
                try wire.appendSlice(allocator, "\r\n");
            }
            response.headers_wire = try wire.toOwnedSlice(allocator);
        },
        @intFromEnum(ipc.ingress_channel.Op.response_chunk) => {
            try body.appendSlice(allocator, payload);
        },
        @intFromEnum(ipc.ingress_channel.Op.response_end) => {
            response.response_end_ns = try process.monotonicNowNs();
        },
        @intFromEnum(ipc.ingress_channel.Op.response_reset) => return error.ResponseReset,
        else => return error.InvalidIngressWorkerDescriptor,
    }
}
