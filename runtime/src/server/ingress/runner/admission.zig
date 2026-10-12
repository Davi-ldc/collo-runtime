//! The admission of each new HTTP/2 stream on an ingress lane thread of the
//! server: the route match, the server's own paths, the lane request slot
//! and the deadline a matched request takes, its place in the pool of its
//! worker definition, and every answer the lane gives a stream before
//! admitting it, with that answer's access record (`answerUnadmitted`),
//! including the heads the HTTP/2 layer refused (`refuseH2Stream`). When a
//! request has to wait, and after a worker of the pool dies
//! (`worker_fault.zig`), the lane asks the launcher for a worker or answers
//! 503 to the waiters nothing can serve (`growOrStrand`). The lookups of a
//! request's slot and connection by the keys admission gives them are here
//! too.
//!
//! Invariants:
//! - The request path alone selects the route, matched once per stream
//!   (`streamTarget`) against the immutable route table
//!   (`server/routes/table.zig`). A path under the server's reserved prefix is
//!   the server's own and never reaches the table: the health path is
//!   answered from the server's state, and every other one is not found. The
//!   parser refuses every pattern under the prefix too
//!   (`server/config/pattern.zig`). The authority selects nothing; it reaches
//!   the worker only as the request's normalized authority
//!   (`request_head.normalizeAuthority`), the `host` header and the base of
//!   `request.url`.
//! - The lane assigns the route key, the request id and the access facts'
//!   identity from its own match and tables, never from worker output.
//! - A request's one deadline, its arrival (`ParsedHead.received_ns`, the
//!   socket read that brought its head) plus its definition's `timeoutMs`,
//!   is fixed here with its lane request slot and its wheel entry, before
//!   its pool sees it. The request keeps all three whether it dispatches at
//!   once or waits in the pool's FIFO as this lane's own state. Later steps
//!   move its wheel entry (`dispatch.zig`, `deadline_driver.zig`) and leave
//!   the deadline as admission set it.
//! - A stream handler that the HTTP/2 driver (`http2/connection.zig`) calls
//!   returns only a lane fault or an `Http2Error` (`StreamError`), which the
//!   driver classifies.
//! - A request yields at most one access record: an admitted request emits
//!   when it finishes (`request_finish.zig`), and a stream the lane answers
//!   before admitting it emits at that answer. `answerUnadmitted` is the one
//!   place such an answer is given, and its exhaustive `UnadmittedAnswer`
//!   decides for each kind what the client gets and whether the access log
//!   hears of it: every answer with a status records under a fresh request
//!   id, except the health answer, and the RST_STREAM of a refused stream
//!   records nothing and is counted (`streams_refused`).
//! - The health answer reads the server's state without a lock
//!   (`healthState`), so a lane gives it without waiting on another thread,
//!   and a stopping server still gives it, so it comes before the stop check
//!   that refuses a new request.

const std = @import("std");
const process = @import("collo_os").process;
const lifecycle = @import("collo_server_lifecycle");
const server_config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const supervision = @import("collo_server_supervisor");
const ipc = @import("collo_ipc");
const hpack = @import("collo_hpack");
const fault = @import("../fault.zig");
const PeerAddress = @import("../peer_address.zig").PeerAddress;
const server_responses = @import("../server_responses.zig");
const h2_request = @import("../http2/root.zig").request_head;
const http2_writing = @import("../http2/writing.zig");
const connection_slot = @import("connection_slot.zig");
const deadline_driver = @import("deadline_driver.zig");
const dispatch = @import("dispatch.zig");
const request_finish = @import("request_finish.zig");
const request_slot_mod = @import("request_slot.zig");
const worker_registration = @import("worker_registration.zig");

const access_log = @import("collo_server_analytics").access;
const Sink = @import("collo_server_analytics").Sink;
const http_body_limits = @import("collo_limits").http_body;
const pool_limits = @import("collo_limits").pool;
const record_limits = @import("collo_limits").runtime_logs;

const ConnectionSlot = connection_slot.Slot;
const RequestSlot = request_slot_mod.RequestSlot;
const DispatchHead = request_slot_mod.DispatchHead;
const OwnedHead = request_slot_mod.OwnedHead;
const LaneFault = fault.LaneFault;
const GrowthReason = supervision.launcher.GrowthReason;
const pool = supervision.pool;

/// What a stream handler that the HTTP/2 driver (`http2/connection.zig`)
/// calls may return: a lane fault, or an error the driver sorts into the
/// connection's outcome (`fault.classifyConnectionError`).
pub const StreamError = fault.LaneFault || fault.Http2Error;

/// The worker identity of a request that has no worker yet.
const no_worker: lifecycle.WorkerKey = .{ .worker_id = 0, .worker_generation = 0 };

/// Waiters one `takeStranded` call moves out of the pool.
const stranded_batch_len: usize = 16;

/// What the lane does with a new stream, decided from its path alone.
pub const StreamTarget = union(enum) {
    /// The server's own health path (`config.pattern.health_path`).
    health,
    /// No route matches the path, it is deeper than any pattern can be, or
    /// it is one of the server's own paths with no answer.
    not_found,
    matched: routes_mod.Match,
};

/// What the lane answers a stream before admitting it. `answerUnadmitted`
/// switches over every kind, so a new early answer does not build until it
/// decides what the client gets and whether the access log hears of it.
pub const UnadmittedAnswer = union(enum) {
    /// The server's health path, answered from the server's state with no
    /// access record: a probe every few seconds would flood the log.
    health,
    /// No route matches the path, or it is one of the server's own paths
    /// with no answer: 404.
    not_found,
    /// A head with more fields or decoded bytes than a head may hold: 431,
    /// naming the route when the head matched one.
    header_fields_too_large: ?server_config.RouteKey,
    /// A head whose block decoded but that RFC 9113 §8.3 calls malformed:
    /// 400. Its path never reaches the route table.
    malformed,
    /// A matched head that declares a body over
    /// `http_body.MATERIALIZED_BODY_BYTES_MAX`: 413.
    payload_too_large: server_config.RouteKey,
    /// A matched head while the server stops admitting requests: 503.
    stopping: server_config.RouteKey,
    /// No room for the stream on its connection or on the lane:
    /// RST_STREAM REFUSED_STREAM, which the client may retry, with no
    /// access record, since no HTTP status went out; counted instead
    /// (`streams_refused`).
    refused,
};

/// What the lane knows of a stream it answers before admission. The strings
/// are borrowed for the call.
pub const UnadmittedStream = struct {
    stream_id: u32,
    /// The END_STREAM flag of the head's frame. A client still sending its
    /// request is asked to stop once the answer is queued
    /// (`http2/writing.zig:answerStreamAlone`).
    request_ended: bool,
    /// When the head arrived (`ParsedHead.received_ns`), where the answer's
    /// access record starts.
    received_ns: u64,
    method: []const u8,
    path: []const u8,
    user_agent: []const u8,

    pub fn ofHead(stream_id: u32, head: *const h2_request.ParsedHead) UnadmittedStream {
        return .{
            .stream_id = stream_id,
            .request_ended = head.end_stream,
            .received_ns = head.received_ns,
            .method = head.method,
            .path = head.path,
            .user_agent = access_log.userAgent(head.headers),
        };
    }

    pub fn ofRefused(stream_id: u32, refused: *const h2_request.RefusedHead) UnadmittedStream {
        return .{
            .stream_id = stream_id,
            .request_ended = refused.request_ended,
            .received_ns = refused.received_ns,
            .method = refused.method,
            .path = refused.path,
            .user_agent = refused.user_agent,
        };
    }
};

/// Classifies a new stream by its request path: a path under the server's
/// reserved prefix first (`config.pattern.isReserved`), which is the health
/// path or not found, then the route table. The authority is not an input,
/// so two requests for one path reach the same route whatever host they
/// name. Captures land in `captures`, which a match borrows.
pub fn streamTarget(table: *const routes_mod.Table, path: []const u8, captures: *routes_mod.Captures) StreamTarget {
    if (server_config.pattern.isReserved(path)) {
        if (std.mem.eql(u8, path, server_config.pattern.health_path))
            return .health;
        return .not_found;
    }
    const matched = table.match(path, captures) catch |err| switch (err) {
        // Deeper than any pattern can be, so no route serves it.
        error.PathTooDeep => return .not_found,
    };
    return if (matched) |found| .{ .matched = found } else .not_found;
}

/// The server's state as the health answer reports it: `stopping` as the
/// service says, the zygote alive while `zygote_pidfd` reports no exit, a
/// lane running only while the state it published is `active`, and the
/// usage stream's full flag. Each read is one atomic load or one
/// zero-timeout poll, so it takes no lock. `lanes` is a slice of lanes, each
/// with `state()`, and holds at most `maxInt(u16)` of them, the bound
/// `Service.init` keeps.
pub fn healthState(
    stopping: bool,
    zygote_pidfd: std.posix.fd_t,
    lanes: anytype,
    analytics: *const Sink,
) server_responses.HealthState {
    std.debug.assert(lanes.len <= std.math.maxInt(u16));
    var lanes_running: u16 = 0;
    for (lanes) |*lane| {
        if (lane.state() == .active)
            lanes_running += 1;
    }
    return .{
        .stopping = stopping,
        .zygote_alive = !process.pidFdHasExited(zygote_pidfd),
        .lanes_running = lanes_running,
        .lanes_total = @intCast(lanes.len),
        .usage_stream_full = analytics.full(.usage),
    };
}

/// The request headers a worker sees, and the only producer of a dispatch's
/// header list: every client header, with `host` replaced by the request's
/// normalized authority, the same value the dispatch carries as
/// `authority`, from which the worker builds the request's URL.
fn h2HeadersForIpc(
    out: *[ipc.max_request_header_count]ipc.RequestHeader,
    authority: []const u8,
    headers: []const hpack.Header,
) error{TooManyRequestHeaders}![]const ipc.RequestHeader {
    var forwarded_count: usize = 1;
    for (headers) |header| {
        if (!std.mem.eql(u8, header.name, "host"))
            forwarded_count += 1;
    }
    if (forwarded_count > out.len)
        return error.TooManyRequestHeaders;
    out[0] = .{ .name = "host", .value = authority };
    var cursor: usize = 1;
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, "host"))
            continue;
        out[cursor] = .{ .name = header.name, .value = header.value };
        cursor += 1;
    }
    return out[0..cursor];
}

pub fn Methods(comptime Self: type) type {
    return struct {
        const Dispatch = dispatch.Methods(Self);
        const RequestFinish = request_finish.Methods(Self);
        const WorkerRegistration = worker_registration.Methods(Self);

        /// Admits a new stream. A stream whose path matches a route takes its
        /// lane request slot and its deadline, then a worker slot from its
        /// definition's pool or a place in the pool's FIFO; every other
        /// stream gets the lane's own answer (`answerUnadmitted`). A stream
        /// the connection or the lane has no room for is refused alone, so
        /// the client may retry it. Returns false when the stream cannot be
        /// opened, which the connection driver answers as a protocol error.
        pub fn startDynamicH2(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            head: *const h2_request.ParsedHead,
        ) StreamError!bool {
            const stream = UnadmittedStream.ofHead(stream_id, head);
            if (!try reserveStream(self, runtime, stream))
                return true;
            self.lane.counters.ingress_channels_started += 1;

            var captures: routes_mod.Captures = undefined;
            const matched = switch (streamTarget(&self.service.routes.table, head.path, &captures)) {
                .health => {
                    try answerUnadmitted(self, runtime, stream, .health);
                    return true;
                },
                .not_found => {
                    try answerUnadmitted(self, runtime, stream, .not_found);
                    return true;
                },
                .matched => |found| found,
            };
            // Checked once the route is known, so the 413's record names it.
            if (head.content_length) |length| {
                if (length > http_body_limits.MATERIALIZED_BODY_BYTES_MAX) {
                    try answerUnadmitted(self, runtime, stream, .{ .payload_too_large = matched.key });
                    return true;
                }
            }

            // The one place a request is admitted. Refusing new ones once
            // `shouldStop()` trips lets the lane's shutdown drain
            // (`ring_driver.zig`) run out under continuous traffic; requests
            // admitted before the stop drain normally.
            if (self.service.shouldStop()) {
                try answerUnadmitted(self, runtime, stream, .{ .stopping = matched.key });
                return true;
            }
            self.lane.counters.route_matches += 1;

            var header_storage: [ipc.max_request_header_count]ipc.RequestHeader = undefined;
            const request_headers = h2HeadersForIpc(&header_storage, head.authority(), head.headers) catch |err| switch (err) {
                // The head decoder bounds the header count to what a dispatch
                // carries, so only a decoder bound looser than the dispatch's
                // reaches this.
                error.TooManyRequestHeaders => {
                    try answerUnadmitted(self, runtime, stream, .{ .header_fields_too_large = matched.key });
                    return true;
                },
            };

            // Until a request binds it, the stream leaves the table on every
            // way out.
            var stream_unclaimed = true;
            defer if (stream_unclaimed) {
                _ = runtime.h2RemoveStream(self.service.allocator, stream_id);
            };
            runtime.h2SetRequestBodyExpectation(stream_id, head.body_framing, head.content_length, head.end_stream) catch return false;
            const acquired = self.requests.acquire() orelse {
                // The lane request slab is full. Only this stream is shed, so
                // the client may retry it; the connection and every other
                // stream on the lane stay.
                stream_unclaimed = false;
                try answerUnadmitted(self, runtime, stream, .refused);
                return true;
            };
            const now = self.monotonicNowNs();
            const definition = self.service.routes.definition(matched.key.definition);
            const deadline_ns = head.received_ns +| definition.settings.limits.timeoutNs();
            const request_id = self.service.allocateRequestId();
            const slot = acquired.entry;
            slot.request_key = .{ .lane_id = self.lane.lane_id, .slot = acquired.index, .generation = acquired.generation };
            slot.request_id = request_id;
            slot.connection_key = runtime.key;
            slot.ingress_channel_id = stream_id;
            slot.route = matched.key;
            slot.deadline_ns = deadline_ns;
            slot.admitted_ns = head.received_ns;
            {
                errdefer {
                    _ = self.lane.cancelRequestDeadline(&slot.deadline);
                    self.requests.release(acquired.index);
                }
                try insertWheelEntry(self, slot, deadline_ns, now);
                try runtime.h2BindRequest(stream_id, slot.request_key, request_id);
            }
            // From here the request owns the stream: its finish answers or
            // removes it.
            stream_unclaimed = false;
            slot.access = stampAccessFacts(self, runtime, matched.key, .{
                .request_id = request_id,
                .method = head.method,
                .path = head.path,
                .user_agent = stream.user_agent,
                .started_mono_ns = head.received_ns,
            });
            self.request_count += 1;
            try placeRequest(self, acquired.index, .{
                .authority = head.authority(),
                .method = head.method,
                .path = head.path,
                .raw_query = head.raw_query,
                .request_headers = request_headers,
                // The route table hands out the dispatch message's own
                // capture type, borrowing the pattern and the request path.
                .route_captures = matched.captures,
                .body_framing = workerH2BodyFraming(head),
            });
            return true;
        }

        /// Asks the pool of the request's definition for a worker slot for
        /// the waiting request in `request_slot`: a free slot dispatches it
        /// at once, a full house queues it as a waiter with its own copy of
        /// `head` and may start a launch, and a full FIFO answers 503. `head`
        /// is borrowed for the call, from the decoder or from the request's
        /// own copy.
        fn placeRequest(self: *Self, request_slot: u32, head: DispatchHead) LaneFault!void {
            const slot = &self.requests.entries[request_slot];
            const definition = slot.route.definition;
            const definition_pool = self.service.supervisor.poolFor(definition);
            switch (definition_pool.acquire(self.lane.lane_id, slot.request_key, slot.deadline_ns)) {
                .acquired => |acquired| {
                    self.lane.counters.worker_pool_ready_picks += 1;
                    try WorkerRegistration.dischargeReaderGrant(self, acquired.worker, acquired.reader);
                    try Dispatch.dispatchWithHead(self, request_slot, acquired.worker, acquired.slot, head);
                },
                .wait => {
                    // The decoder's buffers are gone by the time a slot
                    // reaches the request, so it keeps its own copy.
                    if (slot.head == null) {
                        slot.head = OwnedHead.init(self.service.allocator, head) catch |err| switch (err) {
                            error.OutOfMemory => return RequestFinish.finishRequest(self, request_slot, .unserved),
                        };
                    }
                    try growOrStrand(self, definition, .waiter);
                },
                .full => try RequestFinish.finishRequest(self, request_slot, .unserved),
            }
        }

        /// Asks the pool again for a waiting request whose handed slot came
        /// from a worker that left service before the request could use it.
        pub fn placeWaitingRequest(self: *Self, request_slot: u32) LaneFault!void {
            const slot = &self.requests.entries[request_slot];
            if (!slot.waiting())
                return;
            // A request that waits owns its head (`placeRequest`).
            const owned = slot.head orelse return error.RequestSlotVacant;
            try placeRequest(self, request_slot, owned.head);
        }

        /// Starts a launch for `definition` when its pool wants one, or
        /// answers 503 to the waiters nothing can serve: no worker is live
        /// and no launch is in flight, so a refused growth would leave them
        /// waiting out their whole deadline. This lane's own waiters are
        /// answered here, the others through their lanes' queues.
        pub fn growOrStrand(self: *Self, definition: server_config.DefinitionIndex, reason: GrowthReason) LaneFault!void {
            const supervisor = self.service.supervisor;
            const definition_pool = supervisor.poolFor(definition);
            if (definition_pool.growthWanted(supervisor.memoryGate())) {
                self.service.launcher.submit(definition, reason);
                return;
            }
            var stranded_buffer: [stranded_batch_len]pool.Waiter = undefined;
            var batches: usize = 0;
            while (batches <= pool_limits.pool_waiters_max / stranded_batch_len) : (batches += 1) {
                const stranded = definition_pool.takeStranded(&stranded_buffer);
                for (stranded) |waiter| {
                    if (waiter.lane == self.lane.lane_id) {
                        if (waitingRequestSlot(self, waiter.request_key)) |request_slot|
                            try RequestFinish.finishRequest(self, request_slot, .unserved);
                        continue;
                    }
                    // A lane that cannot take it answers the request at its
                    // deadline.
                    if (!try self.postToLane(waiter.lane, .{ .dispatch_failed = .{
                        .request_key = waiter.request_key,
                        .reason = .growth_refused,
                    } }))
                        self.lane.counters.silent_queue_overflows += 1;
                }
                if (stranded.len < stranded_buffer.len)
                    return;
            }
        }

        /// Inserts the admission wheel entry of a request and re-arms the
        /// lane's deadline timerfd only when the entry is due before every
        /// deadline the wheel held. The timerfd stays armed at or before the
        /// wheel's earliest deadline (`deadline_driver.armTimerAt`), and the
        /// wheel keeps a bound no live deadline precedes: exact, or after its
        /// earliest entry left, that entry's deadline. A later entry never
        /// needs a re-arm, and a removed one leaves the timerfd early, which
        /// costs one spurious wake that re-arms it.
        fn insertWheelEntry(self: *Self, slot: *RequestSlot, deadline_ns: u64, now: u64) LaneFault!void {
            const earliest = self.lane.deadline_wheel.next_deadline_monotonic_ns;
            const re_arm = if (earliest) |earliest_ns| deadline_ns < earliest_ns else true;
            try self.lane.armRequestDeadline(&slot.deadline, slot.request_key, slot.connection_key, no_worker, deadline_ns, now);
            if (re_arm)
                try deadline_driver.armTimerAt(Self, self, now);
        }

        /// Queues the lane's own answer `response_id` whole on `stream_id`,
        /// and returns whether it was queued. A stream that can take no
        /// answer, because it is gone, drains one already or carries the
        /// worker's head, gets nothing, and a connection that cannot take
        /// the frames is asked to close (`http2_writing.queueServerResponse`).
        pub fn writeH2ServerResponse(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            response_id: server_responses.Id,
        ) LaneFault!bool {
            return http2_writing.queueServerResponse(Self, self, runtime, stream_id, server_responses.get(response_id));
        }

        pub fn finishH2LocalResponse(self: *Self, runtime: *ConnectionSlot, stream_id: u32) void {
            _ = runtime.h2FinishLocalResponse(self.service.allocator, stream_id);
        }

        /// The HTTP/2 driver's hook for a request head it refused before
        /// parsing it whole (`http2/reading.zig:processRequestHead`): the
        /// stream enters the connection's table, or is refused past its
        /// bounds, and gets 431 or 400 with its access record. The head's
        /// path never reaches the route table, which takes only heads
        /// `request_head.parse` accepted.
        pub fn refuseH2Stream(
            self: *Self,
            runtime: *ConnectionSlot,
            stream_id: u32,
            refused: *const h2_request.RefusedHead,
        ) StreamError!void {
            const stream = UnadmittedStream.ofRefused(stream_id, refused);
            if (!try reserveStream(self, runtime, stream))
                return;
            try answerUnadmitted(self, runtime, stream, switch (refused.reason) {
                .fields_too_large => .{ .header_fields_too_large = null },
                .malformed => .malformed,
            });
        }

        /// The one place the lane answers a stream before admitting it: it
        /// writes `answer` on `stream`, which the connection's table holds
        /// unless the answer is `refused`, ends the stream's tie to the
        /// lane, and pushes the access record the answer calls for. A
        /// recorded answer takes a fresh request id, so the record's join on
        /// worker and request ids stays unique, and names the server as its
        /// author, no worker, `done` as its error code and its route when the
        /// head matched one.
        pub fn answerUnadmitted(
            self: *Self,
            runtime: *ConnectionSlot,
            stream: UnadmittedStream,
            answer: UnadmittedAnswer,
        ) StreamError!void {
            switch (answer) {
                .refused => {
                    self.lane.counters.streams_refused += 1;
                    // A stream refused at its reservation never entered the
                    // table, and one refused for the request slab leaves it.
                    _ = runtime.h2RemoveStream(self.service.allocator, stream.stream_id);
                    try http2_writing.queueRstStream(Self, self, runtime, stream.stream_id, .refused_stream);
                },
                .health => {
                    // The HTTP/2 layer copies the body before it returns, so
                    // the body lives on this stack.
                    var body_buffer: [server_responses.health_body_bytes_max]u8 = undefined;
                    const response = server_responses.health(healthState(
                        self.service.shouldStop(),
                        self.service.supervisor.zygote_process.pidfd,
                        self.service.lanes,
                        self.service.analytics,
                    ), &body_buffer);
                    _ = try http2_writing.answerStreamAlone(Self, self, runtime, stream.stream_id, response, stream.request_ended);
                },
                .not_found => try answerRecorded(self, runtime, stream, .route_not_found, null),
                .header_fields_too_large => |route| try answerRecorded(self, runtime, stream, .request_header_fields_too_large, route),
                .malformed => try answerRecorded(self, runtime, stream, .bad_request, null),
                .payload_too_large => |route| try answerRecorded(self, runtime, stream, .payload_too_large, route),
                .stopping => |route| try answerRecorded(self, runtime, stream, .service_unavailable, route),
            }
        }

        /// Answers `stream` with `response_id` and pushes its access record
        /// (`answerUnadmitted`), whose first byte is the answer's when the
        /// stream took it.
        fn answerRecorded(
            self: *Self,
            runtime: *ConnectionSlot,
            stream: UnadmittedStream,
            response_id: server_responses.Id,
            route: ?server_config.RouteKey,
        ) LaneFault!void {
            const response = server_responses.get(response_id);
            const queued = try http2_writing.answerStreamAlone(Self, self, runtime, stream.stream_id, response, stream.request_ended);
            const answered_ns = self.monotonicNowNs();
            var facts = stampAccessFacts(self, runtime, route, .{
                .request_id = self.service.allocateRequestId(),
                .method = stream.method,
                .path = stream.path,
                .user_agent = stream.user_agent,
                .started_mono_ns = stream.received_ns,
            });
            if (queued)
                facts.first_byte_mono_ns = answered_ns;
            _ = self.access_ring.push(access_log.recordFromFacts(facts, response.status, .server, answered_ns));
        }

        /// Takes `stream` into the connection's stream table and returns
        /// true. Past the connection's concurrent streams or the lane's
        /// stream slab, the stream is refused alone (`answerUnadmitted`) and
        /// the call returns false. The HTTP/2 layer hands only stream ids
        /// above every one the client used, so an id already open is the
        /// lane's own mistake, which closes the connection.
        fn reserveStream(self: *Self, runtime: *ConnectionSlot, stream: UnadmittedStream) StreamError!bool {
            runtime.h2ReserveStream(stream.stream_id) catch |err| switch (err) {
                error.Http2TooManyConcurrentStreams, error.Http2StreamSlabFull => {
                    try answerUnadmitted(self, runtime, stream, .refused);
                    return false;
                },
                error.Http2StreamAlreadyOpen => return error.Http2StreamAlreadyOpen,
            };
            return true;
        }

        /// Access facts for a request on `runtime`'s connection. The worker
        /// and route come from the route table: the matched route's
        /// definition name and pattern, or "" for both when the request
        /// matched no route. The client address is the connection's TCP
        /// peer. Every string is copied, so the facts outlive the head.
        fn stampAccessFacts(
            self: *Self,
            runtime: *const ConnectionSlot,
            route: ?server_config.RouteKey,
            request: RequestFacts,
        ) access_log.AccessFacts {
            const routes = self.service.routes;
            var client_ip: PeerAddress.TextBuffer = undefined;
            return access_log.stamp(.{
                .request_id = request.request_id,
                .worker = if (route) |key| routes.definition(key.definition).name else "",
                .route = if (route) |key| routes.route(key).pattern else "",
                .method = request.method,
                .path = request.path,
                .user_agent = request.user_agent,
                .client_ip = runtime.peer_address.text(&client_ip),
                .started_mono_ns = request.started_mono_ns,
            });
        }

        /// The slot of the request `request_key` names when it is still
        /// this lane's and live, waiting or dispatched.
        pub fn findRequestSlot(self: *Self, request_key: lifecycle.RequestKey) ?u32 {
            if (request_key.lane_id != self.lane.lane_id)
                return null;
            return switch (self.requests.lookup(request_key.slot, request_key.generation)) {
                .live => request_key.slot,
                .stale_generation, .vacant, .out_of_range => null,
            };
        }

        /// `findRequestSlot` for a request that still waits for a worker
        /// slot, which a `dispatch_ready` or `dispatch_failed` for it needs.
        pub fn waitingRequestSlot(self: *Self, request_key: lifecycle.RequestKey) ?u32 {
            const request_slot = findRequestSlot(self, request_key) orelse return null;
            if (!self.requests.entries[request_slot].waiting())
                return null;
            return request_slot;
        }

        /// The HTTP/2 connection of the request in `slot`, or null once it
        /// closed.
        pub fn requestConnection(self: *Self, slot: *const RequestSlot) ?*ConnectionSlot {
            const runtime = switch (self.connections.lookup(slot.connection_key.slot, slot.connection_key.generation)) {
                .live => |runtime| runtime,
                .stale_generation, .vacant, .out_of_range => return null,
            };
            if (runtime.state != .http2_connection)
                return null;
            return runtime;
        }

        fn workerH2BodyFraming(head: *const h2_request.ParsedHead) ipc.RequestBodyFraming {
            return if (head.end_stream) .none else .ingress_channel;
        }
    };
}

/// What `stampAccessFacts` copies from one request besides the route and the
/// client address. Strings are borrowed for the call.
const RequestFacts = struct {
    request_id: u64,
    method: []const u8,
    path: []const u8,
    user_agent: []const u8,
    started_mono_ns: u64,
};

comptime {
    // The access facts hold every address text the peer formatter writes.
    std.debug.assert(PeerAddress.text_bytes_max <= record_limits.CLIENT_IP_BYTES_MAX);
}
