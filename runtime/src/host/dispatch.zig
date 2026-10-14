//! The host side of one request: describe it, send it down the worker's
//! control socket, and read the response back from the same socket. It also
//! builds the sealed definition artifacts a host hands a worker. A worker
//! registers its definition's artifact and learns its routes from it before
//! its first request, from WorkerInit (`LaunchOptions.routes` in
//! `launch.zig`), so a request names its route by its index and carries no
//! module. Harnesses and benchmarks use it; the server's lanes read workers
//! on their own.
//!
//! Response frames (head, chunks, end) arrive as ingress-channel packets on
//! the control socket, a chunk above the inline threshold through the
//! worker's payload ring (`ResponseChannels.ingress_payload`), and the
//! request's `request_done` closes them: the worker sends it after every
//! other descriptor of the request, so the read ends there, with the
//! worker's status and measures (`ipc.ingress_channel.RequestDone`). A
//! `request_done` may come without a head, from a worker that failed the
//! request before answering it. Every host reads the same way, in-process
//! harnesses and forked workers alike. The reader grants the worker response
//! credit for each chunk it takes, as the server does (`ResponseReadCredit`),
//! so a worker's response may run past its first
//! `common/ipc/response_credit.zig:window` chunks.

const std = @import("std");
const ipc = @import("collo_ipc");
const body_limits = @import("collo_limits").http_body;
const fd_mod = @import("collo_os").fd;

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
    /// The route's index among the routes of the worker's definition
    /// artifact, in route order (`ipc.DispatchWorkView.route_index`).
    route_index: u16 = 0,
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
    /// The worker's live slot the request runs in
    /// (`ipc.DispatchWorkView.worker_slot`); a host that sends one request at
    /// a time keeps 0.
    worker_slot: u8 = 0,
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
        .worker_slot = parts.worker_slot,
        .authority = parts.authority,
        .deadline_monotonic_ns = parts.deadline_monotonic_ns,
        .method = parts.request.method,
        .path = parts.request.path,
        .raw_query = parts.request.raw_query,
        .request_headers = parts.request.headers,
        .body_framing = bodyFraming(parts.request),
        .route_captures = parts.route_captures,
        .route_index = parts.route_index,
    });
}

pub fn bodyFraming(request: Request) ipc.RequestBodyFraming {
    if (request.body.len != 0)
        return .ingress_channel;
    return request.body_framing;
}

/// A sealed memfd holding a definition artifact with one module, `source`
/// at `specifier`, and one route to it with no bindings
/// (`module_pack.buildSingleRouteAlloc`): the smallest artifact a worker
/// launches with. The caller owns the fd.
pub fn createModulePackFd(allocator: std.mem.Allocator, specifier: []const u8, source: []const u8) !std.posix.fd_t {
    const pack = try ipc.module_pack.buildSingleRouteAlloc(allocator, specifier, source);
    defer allocator.free(pack);
    return createSealedPackFd("collo-definition", pack);
}

/// A sealed memfd holding a definition artifact with `modules` and
/// `routes`, each route's `entry_module` an index into `modules`
/// (`module_pack.buildAlloc`). The caller owns the fd.
pub fn createDefinitionFd(
    allocator: std.mem.Allocator,
    modules: []const ipc.module_pack.Module,
    routes: []const ipc.route_table.RouteInput,
) !std.posix.fd_t {
    const pack = try ipc.module_pack.buildAlloc(allocator, modules, routes);
    defer allocator.free(pack);
    return createSealedPackFd("collo-definition", pack);
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

/// Where a host reads one worker's responses.
pub const ResponseChannels = struct {
    /// Host end of the worker's control socket.
    control_fd: std.posix.fd_t,
    /// The host's mapping of the worker's payload ring, through which the
    /// worker sends a chunk above the inline threshold; null for a reader
    /// whose worker sends every chunk inline.
    ingress_payload: ?*ipc.ingress_channel.SharedPayloadView = null,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    /// The response head's status; 200 when the worker sent no head.
    status: u16 = 200,
    /// The worker's `request_done` for the request: its status and measures.
    /// `readResponse` returns only after the `request_done` that ends the
    /// read set it.
    done: ipc.ingress_channel.RequestDone = undefined,
    /// `name: value\r\n` per header, in wire order.
    headers_wire: []u8 = &.{},
    body: []u8 = &.{},
    /// The reason of a `worker_retiring` notice read among this response's
    /// frames. A worker may send its one notice at any point after
    /// WorkerReady, so the reader takes it wherever it falls and reports it
    /// here.
    retiring: ?ipc.WorkerRetiringReason = null,

    /// The status the worker's `request_done` names.
    pub fn doneStatus(self: *const Response) ipc.RequestDoneStatus {
        return self.done.status;
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
    /// For a host that runs the worker on its own thread: one bounded pass
    /// of the worker, called before each read. With it, a poll that finds
    /// nothing waits at most a millisecond before the next pass.
    progress_context: ?*anyopaque = null,
    progress_fn: ?*const fn (?*anyopaque) anyerror!void = null,
};

/// Bounded read of one request's response: takes packets from the control
/// socket until the request's `request_done`, which the worker sends after
/// every other descriptor of the request, so nothing of the request is left
/// queued when the read returns. Returns `error.ResponseNotFinalized` after
/// `budget.wall_ms` instead of blocking, `error.ResponseBodyTooLarge` /
/// `error.ResponseHeadersTooLarge` the moment a frame would push the
/// accumulated bytes past the byte caps, `error.ControlPeerClosed` when the
/// worker closes its end before its `request_done`, and
/// `error.DescriptorAfterRequestDone` for a descriptor a packet carries
/// after it.
pub fn readResponse(
    allocator: std.mem.Allocator,
    channels: ResponseChannels,
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

    var credit = ResponseReadCredit{ .request_id = request_id };
    var timer = try std.time.Timer.start();
    const budget_ns = @as(u64, budget.wall_ms) * std.time.ns_per_ms;
    var done = false;
    // Each turn waits at most until the budget runs out and returns once it
    // has, so the loop ends by `budget.wall_ms` at the latest.
    while (!done) {
        if (budget.progress_fn) |progress|
            try progress(budget.progress_context);
        credit.flush(channels.control_fd) catch |err| switch (err) {
            // The read below reports the hang-up.
            error.PeerClosed => credit.pending = false,
            else => return err,
        };

        const elapsed_ns = timer.read();
        if (elapsed_ns >= budget_ns)
            return error.ResponseNotFinalized;
        const remaining_ms: i32 = @intCast(@divFloor(budget_ns - elapsed_ns, std.time.ns_per_ms) + 1);
        var pollfds = [1]std.posix.pollfd{.{
            .fd = channels.control_fd,
            .events = std.posix.POLL.IN | (if (credit.pending) @as(i16, std.posix.POLL.OUT) else 0),
            .revents = 0,
        }};
        // With a worker to run, each pass of it may queue what the next look
        // finds, so a look waits no longer than a millisecond.
        const wait_ms = if (budget.progress_fn != null) @min(remaining_ms, 1) else remaining_ms;
        const ready = std.posix.poll(&pollfds, wait_ms) catch return error.ResponseChannelClosed;
        if (ready == 0)
            continue;
        if ((pollfds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0)
            return error.ControlChannelBroken;
        // A hang-up with nothing queued reads as the peer closing, which the
        // drain reports.
        if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) == 0)
            continue;
        done = try drainResponseControlPacket(allocator, channels, budget, &response, &body, &credit);
    }
    response.body = try body.toOwnedSlice(allocator);
    return response;
}

/// The response credit of one response a host reads. The response's
/// identity is pinned by its head, which must come first, and every later
/// descriptor must carry it. Each chunk is charged as it is decoded and
/// retired once its packet was read whole, which sends the worker a new
/// cumulative grant.
pub const ResponseReadCredit = struct {
    request_id: u64,
    /// The grant to send, which carries the pinned identity.
    identity: ?ipc.ResponseCredit = null,
    window: ipc.response_credit.Window = .{},
    /// A grant waits for room in the control socket.
    pending: bool = false,
    ended: bool = false,

    /// Checks `descriptor` against the response and charges a chunk. A chunk
    /// past the window fails with `error.ResponseCreditExceeded`.
    pub fn admit(self: *ResponseReadCredit, descriptor: ipc.ingress_channel.Descriptor) !void {
        if (self.ended)
            return error.InvalidH2StreamIdentity;
        try self.checkIdentity(descriptor);
        if (self.identity != null) {
            if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_head))
                return error.InvalidH2WorkerInboundDescriptor;
        } else {
            if (descriptor.op != @intFromEnum(ipc.ingress_channel.Op.response_head))
                return error.InvalidH2WorkerInboundDescriptor;
            self.identity = .{
                .request_lane_id = descriptor.request_lane_id,
                .request_slot = descriptor.request_slot,
                .stream_id = descriptor.stream_id,
                .request_id = descriptor.request_id,
                .request_generation = descriptor.request_generation,
                .grant_chunks_total = self.window.granted,
            };
        }
        if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_chunk)) {
            if (descriptor.byte_len == 0 or descriptor.byte_len > body_limits.INGRESS_RESPONSE_CHUNK_BYTES)
                return error.InvalidH2WorkerInboundDescriptor;
            if (!self.window.trySpend())
                return error.ResponseCreditExceeded;
        }
        if (descriptor.hasFlag(ipc.ingress_channel.flags.end_stream) or
            descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_end) or
            descriptor.op == @intFromEnum(ipc.ingress_channel.Op.response_reset))
            self.ended = true;
    }

    /// Checks that a `request_done` names this response. It may follow the
    /// response's end, or come without a head from a worker that failed the
    /// request first; nothing of the response follows it, so no grant is
    /// sent after it.
    pub fn admitDone(self: *ResponseReadCredit, descriptor: ipc.ingress_channel.Descriptor) !void {
        try self.checkIdentity(descriptor);
        self.ended = true;
        self.pending = false;
    }

    /// The descriptor names this response's request and, once a head pinned
    /// the response's identity, carries that identity whole.
    fn checkIdentity(self: *const ResponseReadCredit, descriptor: ipc.ingress_channel.Descriptor) !void {
        if (descriptor.request_id != self.request_id)
            return error.InvalidH2StreamIdentity;
        const identity = self.identity orelse return;
        if (identity.request_lane_id != descriptor.request_lane_id)
            return error.InvalidH2StreamIdentity;
        if (identity.request_slot != descriptor.request_slot)
            return error.InvalidH2StreamIdentity;
        if (identity.request_generation != descriptor.request_generation)
            return error.InvalidH2StreamIdentity;
        if (identity.stream_id != descriptor.stream_id)
            return error.InvalidH2StreamIdentity;
    }

    /// Retires `count` admitted chunks; the grant is sent while the response
    /// has not ended.
    pub fn retire(self: *ResponseReadCredit, count: u64) void {
        for (0..count) |_|
            self.identity.?.grant_chunks_total = self.window.retire();
        if (count != 0)
            self.pending = !self.ended;
    }

    /// Sends a pending grant; a full socket keeps it pending.
    pub fn flush(self: *ResponseReadCredit, control_fd: std.posix.fd_t) !void {
        if (!self.pending)
            return;
        ipc.response_credit.send(control_fd, self.identity.?) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        self.pending = false;
    }
};

/// Takes one packet from the control socket into `response` and returns
/// whether it carried the request's `request_done`.
fn drainResponseControlPacket(
    allocator: std.mem.Allocator,
    channels: ResponseChannels,
    budget: ReadBudget,
    response: *Response,
    body: *std.ArrayList(u8),
    credit: *ResponseReadCredit,
) !bool {
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
            const spent_before = credit.window.spent;
            var done = false;
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
                    done = try takeDescriptor(allocator, budget, response, body, credit, done, item.descriptor, item.payload);
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
                done = try takeDescriptor(allocator, budget, response, body, credit, false, received.descriptor, received.payload);
            }
            // The decoder's payloads and ring releases ended with the branch
            // above. The accumulated result is bounded separately by budget.
            credit.retire(credit.window.spent - spent_before);
            return done;
        },
        .worker_retiring => {
            // A worker sends one notice; a second is a broken contract.
            if (response.retiring != null)
                return error.DuplicateRetiringNotice;
            response.retiring = try ipc.worker_retiring.decode(&packet);
            return false;
        },
        else => return error.InvalidMessageKind,
    }
}

/// Takes one descriptor of the response and returns whether it was the
/// request's `request_done`. `done_before` says a `request_done` came first
/// in the same packet, after which the worker may send nothing of the
/// request.
fn takeDescriptor(
    allocator: std.mem.Allocator,
    budget: ReadBudget,
    response: *Response,
    body: *std.ArrayList(u8),
    credit: *ResponseReadCredit,
    done_before: bool,
    descriptor: ipc.ingress_channel.Descriptor,
    payload: []const u8,
) !bool {
    if (done_before)
        return error.DescriptorAfterRequestDone;
    if (descriptor.op == @intFromEnum(ipc.ingress_channel.Op.request_done)) {
        try credit.admitDone(descriptor);
        // The channel's decoder checked the record; this decode only copies
        // it out of the packet.
        response.done = try ipc.ingress_channel.decodeRequestDone(payload);
        return true;
    }
    try credit.admit(descriptor);
    try appendResponsePayload(allocator, budget, response, body, descriptor, payload);
    return false;
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
