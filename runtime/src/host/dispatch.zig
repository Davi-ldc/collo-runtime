//! The host side of one request: describe it, send it down the worker's
//! control socket, and read the response back over the worker's two
//! completion channels. It also builds the sealed module packs a host hands
//! a worker. A worker registers its route's pack before its first request,
//! from WorkerInit's route entry (`LaunchOptions.route_entry` in
//! `launch.zig`), so a request names its route's entry by specifier and
//! carries no pack.
//!
//! Response frames (head, chunks, end) arrive as ingress-channel packets on
//! the control fd; the completion record is published on the shared metrics
//! page and signaled through the completion eventfd. Every host reads the
//! same two channels, in-process harnesses and forked workers alike.

const std = @import("std");
const ipc = @import("collo_ipc");
const fd_mod = @import("collo_os").fd;
const worker_shared_page = @import("collo_worker_state").page;

pub const Request = struct {
    method: []const u8 = "GET",
    path: []const u8 = "/",
    raw_query: []const u8 = "",
    headers: []const ipc.RequestHeader = &.{},
    /// Inline body bytes, sent as one body chunk after the request begins.
    body: []const u8 = "",
    /// Framing when `body` is empty: `.ingress_channel` announces chunks the
    /// host sends later; `.none` closes the request stream at once.
    body_framing: ipc.RequestBodyFraming = .none,
    body_end_stream: bool = true,
};

/// Everything the worker needs to run one request against one route. The
/// identity fields default to a single host that owns a single worker; a
/// host that multiplexes must set them.
pub const Dispatch = struct {
    request_id: u64,
    /// The route's entry, in a pack the worker has registered
    /// (`ipc.DispatchWorkView.route_entry_specifier`).
    route_entry_specifier: []const u8,
    /// Absolute CLOCK_MONOTONIC deadline the worker enforces on the request.
    deadline_monotonic_ns: u64,
    /// The request's authority, the host part of the `request.url` the
    /// worker builds; never empty (`ipc.DispatchWorkView.authority`).
    authority: []const u8,
    request_generation: u64 = 1,
    worker_id: u64 = 1,
    worker_generation: u64 = 1,
    request_lane_id: u16 = 0,
    request_slot: u32 = 0,
    route_captures: []const ipc.RouteCapture = &.{},
    request: Request = .{},
};

pub fn initDispatchWork(allocator: std.mem.Allocator, parts: Dispatch) !ipc.DispatchWork {
    return ipc.DispatchWork.initOwned(allocator, .{
        .request_id = parts.request_id,
        .request_generation = parts.request_generation,
        .worker_id = parts.worker_id,
        .worker_generation = parts.worker_generation,
        .request_lane_id = parts.request_lane_id,
        .request_slot = parts.request_slot,
        .authority = parts.authority,
        .deadline_monotonic_ns = parts.deadline_monotonic_ns,
        .method = parts.request.method,
        .path = parts.request.path,
        .raw_query = parts.request.raw_query,
        .request_headers = parts.request.headers,
        .body_framing = bodyFraming(parts.request),
        .route_captures = parts.route_captures,
        .route_entry_specifier = parts.route_entry_specifier,
    });
}

pub fn bodyFraming(request: Request) ipc.RequestBodyFraming {
    if (request.body.len != 0)
        return .ingress_channel;
    return request.body_framing;
}

/// A sealed memfd holding a one-module pack whose entry is `specifier`.
pub fn createModulePackFd(allocator: std.mem.Allocator, specifier: []const u8, source: []const u8) !std.posix.fd_t {
    const pack = try ipc.module_pack.buildSingleAlloc(allocator, specifier, source);
    defer allocator.free(pack);
    return createSealedPackFd("collo-route-pack", pack);
}

/// A sealed memfd holding a multi-module pack; `entry_index` selects the
/// module the route evaluates.
pub fn createModulePackGraphFd(
    allocator: std.mem.Allocator,
    modules: []const ipc.module_pack.Module,
    entry_index: usize,
) !std.posix.fd_t {
    const pack = try ipc.module_pack.buildAlloc(allocator, modules, entry_index);
    defer allocator.free(pack);
    return createSealedPackFd("collo-route-pack-graph", pack);
}

fn createSealedPackFd(name: [*:0]const u8, pack: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        std.mem.span(name),
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, pack);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return fd;
}

/// Sends the request on the worker's control socket: a request-begin
/// descriptor carrying the encoded DispatchWork inline, then one body chunk
/// when `request.body` is not empty.
pub fn sendRequest(
    control_fd: std.posix.fd_t,
    dispatch: *ipc.DispatchWork,
    stream_id: u32,
    request: Request,
) !void {
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var payload_scratch: [ipc.max_message_bytes]u8 = undefined;
    var view = dispatch.view();
    const payload = try ipc.encodeDispatchWorkInto(&payload_scratch, &view);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = dispatch.request_id,
        .request_generation = dispatch.request_generation,
        .request_lane_id = dispatch.request_lane_id,
        .request_slot = dispatch.request_slot,
    };
    const begin = ipc.ingress_channel.Descriptor.requestBegin(
        identity,
        stream_id,
        0,
        @intCast(payload.len),
        @intCast(dispatch.request_headers.len),
        request.body.len == 0 and request.body_end_stream,
    );
    try ipc.ingress_channel.sendDescriptorPayload(control_fd, begin, payload, &scratch);

    if (request.body.len != 0) {
        const body_descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(
            identity,
            stream_id,
            0,
            @intCast(request.body.len),
            request.body_end_stream,
        );
        try ipc.ingress_channel.sendDescriptorPayload(control_fd, body_descriptor, request.body, &scratch);
    }
}

/// The two channels one worker completes requests on, as the host holds
/// them.
pub const CompletionChannels = struct {
    /// Host end of the worker control fd; -1 when the caller only wants the
    /// completion record (response frames stay queued).
    control_fd: std.posix.fd_t,
    completion_eventfd: std.posix.fd_t,
    metrics: *worker_shared_page.WorkerWriterView,
    ingress_payload: ?*ipc.ingress_channel.SharedPayloadView = null,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    /// The completion record published on the shared metrics page.
    completion: worker_shared_page.WorkerCompletionRecord = std.mem.zeroes(worker_shared_page.WorkerCompletionRecord),
    /// `name: value\r\n` per header, in wire order.
    headers_wire: []u8 = &.{},
    body: []u8 = &.{},

    /// The status the worker published, read as the server reads it
    /// (`request_finish.zig`): a value `RequestDoneStatus` does not name is
    /// `worker_crash`.
    pub fn doneStatus(self: *const Response) ipc.RequestDoneStatus {
        return std.enums.fromInt(ipc.RequestDoneStatus, self.completion.status) orelse .worker_crash;
    }

    pub fn deinit(self: *Response) void {
        if (self.headers_wire.len != 0)
            self.allocator.free(self.headers_wire);
        if (self.body.len != 0)
            self.allocator.free(self.body);
        self.* = undefined;
    }

    pub fn takeBody(self: *Response) []u8 {
        const out = self.body;
        self.body = &.{};
        return out;
    }
};

/// The bounds a host places on one response read. The wall clock caps how
/// long the read blocks; the byte caps stop a worker that streams without
/// end from growing the host's heap for as long as the wall allows. Every
/// host states all three: there is no default a hostile worker could rely on.
pub const ReadBudget = struct {
    /// How long the read may block, independent of the request deadline the
    /// worker enforces (`Dispatch.deadline_monotonic_ns`).
    wall_ms: u32,
    /// Cap on the body bytes accumulated across every chunk.
    max_body_bytes: usize,
    /// Cap on the response head's header bytes as the channel encodes them
    /// (an 8-byte length prefix plus name and value per header). The
    /// `name: value\r\n` form kept in `headers_wire` spends 4 separator
    /// bytes per header, so it never exceeds this cap either.
    max_headers_bytes: usize,
};

/// Bounded read of one request's response. Frames are drained from the
/// control fd while the completion is awaited on the metrics ring; the
/// eventfd is only a wakeup, so the ring is checked first because an earlier
/// read may have consumed the counter for a record still queued. Records
/// must arrive in read order: a foreign record is an error. Returns
/// `error.ResponseNotFinalized` after `budget.wall_ms` instead of blocking,
/// and `error.ResponseBodyTooLarge` / `error.ResponseHeadersTooLarge` the
/// moment a frame would push the accumulated bytes past the byte caps.
pub fn readResponse(
    allocator: std.mem.Allocator,
    channels: CompletionChannels,
    request_id: u64,
    budget: ReadBudget,
) !Response {
    var response = Response{ .allocator = allocator };
    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(allocator);
    errdefer if (response.headers_wire.len != 0) {
        allocator.free(response.headers_wire);
        response.headers_wire = &.{};
    };

    var control_fd = channels.control_fd;
    var timer = try std.time.Timer.start();
    const budget_ns = @as(u64, budget.wall_ms) * std.time.ns_per_ms;
    while (true) {
        // Ring first: the completion may already be published.
        var records: [1]worker_shared_page.WorkerCompletionRecord = undefined;
        const drained = try channels.metrics.drainWorkerCompletions(&records);
        if (drained != 0) {
            if (records[0].external_request_id != request_id)
                return error.UnexpectedCompletionRecord;
            response.completion = records[0];
            // The worker queued every response frame before publishing the
            // completion; drain whatever is still pending on the control fd.
            // A decode failure here is a real error: a malformed frame after
            // the response must not be masked into a truncated success. Only
            // the worker closing its end after publishing, and a spurious
            // readiness wakeup, stop the drain early.
            while (control_fd != -1) {
                var control_poll = [1]std.posix.pollfd{.{
                    .fd = control_fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const control_ready = try std.posix.poll(&control_poll, 0);
                if (control_ready == 0)
                    break;
                // POLLERR and POLLNVAL are channel failures, never "nothing
                // more readable". POLLHUP without POLLIN is the worker
                // closing after publishing, which is benign.
                if ((control_poll[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0)
                    return error.ControlChannelBroken;
                if ((control_poll[0].revents & std.posix.POLL.IN) == 0)
                    break;
                drainResponseControlPacket(allocator, channels, budget, &response, &body) catch |err| switch (err) {
                    error.ControlPeerClosed, error.WouldBlock => break,
                    else => return err,
                };
            }
            response.body = try body.toOwnedSlice(allocator);
            return response;
        }

        const elapsed_ns = timer.read();
        if (elapsed_ns >= budget_ns)
            return error.ResponseNotFinalized;
        const remaining_ms: i32 = @intCast(@divFloor(budget_ns - elapsed_ns, std.time.ns_per_ms) + 1);

        var pollfds = [2]std.posix.pollfd{
            .{
                .fd = control_fd,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            },
            .{
                .fd = channels.completion_eventfd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const ready = std.posix.poll(&pollfds, remaining_ms) catch return error.ResponseChannelClosed;
        if (ready == 0)
            return error.ResponseNotFinalized;

        if ((pollfds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0 or
            (pollfds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0)
            return error.ControlChannelBroken;

        if (control_fd != -1 and
            (pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
        {
            // Drain the control packet first so response bytes sent before
            // the completion was published are never lost to an early return.
            drainResponseControlPacket(allocator, channels, budget, &response, &body) catch |err| switch (err) {
                error.ControlPeerClosed => {
                    // The worker may close after publishing; keep waiting on
                    // the metrics channel for the completion.
                    control_fd = -1;
                },
                error.WouldBlock => {},
                else => return err,
            };
            continue;
        }

        if ((pollfds[1].revents & std.posix.POLL.IN) != 0) {
            var counter_bytes: [8]u8 = undefined;
            // A racing consumer of the counter makes this read WouldBlock,
            // which is benign; anything else is a real channel failure.
            _ = std.posix.read(channels.completion_eventfd, &counter_bytes) catch |err| switch (err) {
                error.WouldBlock => {},
                else => return err,
            };
        }
    }
}

fn drainResponseControlPacket(
    allocator: std.mem.Allocator,
    channels: CompletionChannels,
    budget: ReadBudget,
    response: *Response,
    body: *std.ArrayList(u8),
) !void {
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var packet = ipc.recvPacketWithFdsScratch(allocator, channels.control_fd, &scratch) catch |err| switch (err) {
        error.PeerClosed => return error.ControlPeerClosed,
        else => return err,
    };
    // Ingress decoders consume the packet (they deinit it on every path,
    // including errors), so ownership transfers before the decode call.
    var packet_alive = true;
    defer if (packet_alive) packet.deinit();
    if (packet.bytes.len < @sizeOf(u32))
        return error.ShortRead;
    const kind = try ipc.decodeMessageKind(ipc.packet.readStruct(u32, packet.bytes[0..@sizeOf(u32)]));
    switch (kind) {
        .ingress_channel => {
            packet_alive = false;
            if (ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
                var batch = if (channels.ingress_payload) |ingress_payload|
                    try ipc.ingress_channel.decodeReceivedBatchPacketWithSharedPayload(
                        allocator,
                        &packet,
                        .{ .worker_to_server = ingress_payload },
                    )
                else
                    try ipc.ingress_channel.decodeReceivedBatchPacket(allocator, &packet);
                defer batch.deinit();
                for (batch.items) |item|
                    try appendResponsePayload(allocator, budget, response, body, item.descriptor, item.payload);
            } else {
                var received = if (channels.ingress_payload) |ingress_payload|
                    try ipc.ingress_channel.decodeReceivedPacketWithSharedPayload(
                        allocator,
                        &packet,
                        .{ .worker_to_server = ingress_payload },
                    )
                else
                    try ipc.ingress_channel.decodeReceivedPacket(allocator, &packet);
                defer received.deinit();
                try appendResponsePayload(allocator, budget, response, body, received.descriptor, received.payload);
            }
        },
        else => return error.InvalidMessageKind,
    }
}

/// The head is bounded by its decoder before anything is allocated for it;
/// every body append checks the cap before touching the list, so the
/// accumulated length never exceeds the cap and the remaining room never
/// underflows.
fn appendResponsePayload(
    allocator: std.mem.Allocator,
    budget: ReadBudget,
    response: *Response,
    body: *std.ArrayList(u8),
    descriptor: ipc.ingress_channel.Descriptor,
    payload: []const u8,
) !void {
    switch (descriptor.op) {
        @intFromEnum(ipc.ingress_channel.Op.response_head) => {
            // The decoder's byte bound is the authoritative ruler. A header
            // costs at least its length prefix on the channel, so the same
            // cap bounds the header count.
            var head = try ipc.ingress_channel.decodeResponseHeadBounded(
                allocator,
                payload,
                budget.max_headers_bytes / @sizeOf(ipc.messages.NameValuePacket),
                budget.max_headers_bytes,
            );
            defer head.deinit();
            response.status = head.status;
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
            if (payload.len > budget.max_body_bytes - body.items.len)
                return error.ResponseBodyTooLarge;
            try body.appendSlice(allocator, payload);
        },
        @intFromEnum(ipc.ingress_channel.Op.response_end) => {},
        @intFromEnum(ipc.ingress_channel.Op.response_reset) => return error.ResponseReset,
        else => return error.InvalidH2WorkerInboundDescriptor,
    }
}
