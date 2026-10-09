//! HTTP/2 connection pool of the egress engine. Each gateway shard runs one
//! engine, whose owner thread keeps this pool on its stack and is the only
//! thread that touches it, so sessions, HPACK tables, TLS buffers and
//! flow-control windows carry no locks. Connector threads dial and finish the
//! TLS handshake in `Entry.connectBio`; the owner then adopts the connection
//! into an entry.
//!
//! An entry serves one origin under one transport configuration, security
//! cell and policy (`Key`), so no connection state crosses tenants. Past
//! `max_connection_age_ns` an entry takes no new streams. An idle entry leaves
//! the pool at its idle timeout or maximum age, or at once when it is closing.
//!
//! Every event the pool returns carries in `wire_bytes` the ciphertext the
//! connection moved since the previous event.

const std = @import("std");
pub const data_io = @import("collo_egress_data_io");
const http = @import("collo_http");
const http2 = @import("collo_egress_http2");
pub const readiness = @import("collo_egress_readiness");
pub const transport = @import("collo_egress_transport");

const Header = http.Header;
const DnsCache = transport.DnsCache;
const EgressPolicy = transport.EgressPolicy;
const HttpConnection = transport.HttpConnection;
const IoInterest = transport.IoInterest;
const PoolIsolationId = transport.PoolIsolationId;
const RequestPlan = transport.RequestPlan;
const TlsBioTransport = transport.TlsBioTransport;
const TransportConfig = transport.Config;
const connectStreamWithReadiness = transport.connectStreamWithReadiness;
const prepareRequest = transport.prepareRequest;

pub const Config = struct {
    max_entries: usize = 64,
    /// Idle sessions stay warm because DNS, connect, TLS and ALPN dominate
    /// per-request cost for hot origins. The timeout stays under the common
    /// 300 s idle window of NATs and load balancers, which drop longer-idle
    /// flows silently and would cost the next fetch a full socket timeout to
    /// find out. `max_entries` bounds the memory of the long tail.
    idle_timeout_ns: u64 = 240 * std.time.ns_per_s,
    /// Older sessions stop accepting new streams and leave once idle, which
    /// bounds how long peer settings, HPACK state and TLS state can age.
    max_connection_age_ns: u64 = 30 * 60 * std.time.ns_per_s,
};

pub const BatchRequest = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    method: []const u8,
    body: []const u8,
    headers: []const Header,
    config: TransportConfig,
};

pub const StreamHandle = struct {
    entry: *Entry,
    stream_id: u32,
    /// True when the stream opened on a session that had served earlier
    /// requests. As in undici and Bun, that is the precondition for retrying,
    /// without the caller noticing, a request whose pooled connection proves
    /// dead.
    reused: bool = false,
    /// Billed request bytes written at open: the HPACK header block and the
    /// upload DATA payload the initial windows allowed. It seeds the engine's
    /// billed meter for the request; upload bytes written later arrive in the
    /// terminal event's cumulative `billed_bytes`.
    billed_sent: u64 = 0,
};

/// Outcome of the speculative HTTP/2 connect: the negotiated protocol decides
/// which client owns the live connection. An http/1.1 negotiation is a usable
/// handshake, which the engine parks in the shared HTTP/1 pool instead of
/// paying for a second one.
pub const BioConnectOutcome = union(enum) {
    h2: HttpConnection,
    h1: HttpConnection,
};

/// `needs_connection` means no reusable entry exists and the pool has room
/// for one: the caller dials and calls `adoptConnection`. `entry_failed`
/// means opening the stream broke the entry, so the caller fails every stream
/// on it and removes it. `failed` fails the request without touching any
/// entry.
pub const StartResult = union(enum) {
    pending: StreamHandle,
    failed: anyerror,
    needs_connection,
    entry_failed: struct {
        entry: *Entry,
        err: anyerror,
        reused: bool,
    },
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    config: Config,
    entries: std.array_list.Aligned(*Entry, null) = .empty,
    use_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) Pool {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.entries.items) |entry|
            entry.destroy(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn startRequest(self: *Pool, request: BatchRequest) !StartResult {
        return try self.startRequestWithDriver(request, null);
    }

    pub fn startRequestWithDriver(
        self: *Pool,
        request: BatchRequest,
        data_driver: ?*data_io.Driver,
    ) !StartResult {
        const now_ns = try monotonicNowNs();
        self.evictExpiredIdleWithDriver(now_ns, data_driver);

        var plan = prepareRequest(
            self.allocator,
            request.url,
            request.method,
            request.headers,
            request.config,
        ) catch |err| return .{ .failed = err };
        defer plan.deinit();

        if (plan.target.protocol != .tls)
            return .{ .failed = error.Http2UnsupportedScheme };

        const head = plan.h2RequestHead(request.body);
        http2.validateRequestHead(head) catch |err|
            return .{ .failed = err };

        const entry = self.find(&plan, request.config, now_ns) orelse {
            if (self.config.max_entries == 0)
                return .{ .failed = error.Http2PoolDisabled };
            if (self.entries.items.len >= self.config.max_entries) {
                self.evictLeastRecentlyUsedIdleWithDriver(data_driver);
                if (self.entries.items.len >= self.config.max_entries)
                    return .{ .failed = error.Http2PoolExhausted };
            }
            return .needs_connection;
        };

        return try self.openOnEntry(request, entry, head, now_ns);
    }

    pub fn adoptConnection(
        self: *Pool,
        request: BatchRequest,
        wire: HttpConnection,
    ) !StartResult {
        return try self.adoptConnectionWithDriver(request, wire, null);
    }

    pub fn adoptConnectionWithDriver(
        self: *Pool,
        request: BatchRequest,
        wire: HttpConnection,
        data_driver: ?*data_io.Driver,
    ) !StartResult {
        var owned_wire: ?HttpConnection = wire;
        // A plain defer, because most rejections return `.failed` as a
        // success value of the error union and an errdefer would leak the
        // connection. A connection this call does not consume is closed.
        defer if (owned_wire) |*kept| kept.deinit();
        const now_ns = try monotonicNowNs();
        self.evictExpiredIdleWithDriver(now_ns, data_driver);

        var plan = prepareRequest(
            self.allocator,
            request.url,
            request.method,
            request.headers,
            request.config,
        ) catch |err| return .{ .failed = err };
        defer plan.deinit();

        if (plan.target.protocol != .tls)
            return .{ .failed = error.Http2UnsupportedScheme };

        const head = plan.h2RequestHead(request.body);
        http2.validateRequestHead(head) catch |err|
            return .{ .failed = err };

        if (self.find(&plan, request.config, now_ns)) |entry| {
            // An equivalent entry arrived first, which makes this dial
            // redundant; the defer above folds and closes it.
            return try self.openOnEntry(request, entry, head, now_ns);
        }

        if (self.config.max_entries == 0)
            return .{ .failed = error.Http2PoolDisabled };
        if (self.entries.items.len >= self.config.max_entries) {
            self.evictLeastRecentlyUsedIdleWithDriver(data_driver);
            if (self.entries.items.len >= self.config.max_entries)
                return .{ .failed = error.Http2PoolExhausted };
        }

        const entry = try Entry.createFromConnection(self.allocator, &plan, request.config, owned_wire.?, now_ns);
        owned_wire = null;
        errdefer entry.destroy(self.allocator);
        entry.last_used = self.nextUseOrder();
        try self.entries.append(self.allocator, entry);
        return try self.openOnEntry(request, entry, head, now_ns);
    }

    fn openOnEntry(self: *Pool, request: BatchRequest, entry: *Entry, head: http2.RequestHead, now_ns: u64) !StartResult {
        const reused = entry.opened_once;
        entry.opened_once = true;
        const opened = entry.h2.openRequestAllocMetered(
            &entry.outgoing.writer,
            head,
            request.config.max_response_body_bytes,
            request.allocator,
        ) catch |err| return .{ .entry_failed = .{
            .entry = entry,
            .err = entry.mapOutgoingWriteError(err),
            .reused = reused,
        } };
        entry.flushOutgoing() catch |err| return .{ .entry_failed = .{
            .entry = entry,
            .err = err,
            .reused = reused,
        } };

        entry.last_used = self.nextUseOrder();
        entry.touch(now_ns);
        return .{ .pending = .{
            .entry = entry,
            .stream_id = opened.stream_id,
            .reused = reused,
            .billed_sent = opened.billed_sent,
        } };
    }

    fn nextUseOrder(self: *Pool) u64 {
        self.use_counter +%= 1;
        if (self.use_counter == 0)
            self.use_counter = 1;
        return self.use_counter;
    }

    pub fn readEntryEvent(self: *Pool, entry: *Entry) !http2.Event {
        _ = self;
        try entry.flushOutgoing();
        // Runs before every read, as `Connection.nextUnprocessedStreamFailure`
        // requires of callers that read frames themselves.
        if (entry.h2.nextUnprocessedStreamFailure()) |failure| {
            var owned_failure = failure;
            addConnectionWireBytes(&owned_failure, entry);
            return owned_failure;
        }
        var frames_without_event: usize = 0;
        while (true) {
            var read_result = try entry.frame_reader.readFrom(&entry.wire, entry.h2.session.local_settings.max_frame_size);
            switch (read_result) {
                .wait => return error.Http2WouldBlock,
                .eof => {
                    // A clean TLS EOF (close_notify) truncates only streams
                    // that still expect peer bytes. For streams whose
                    // END_STREAM already arrived, with `.end` waiting on the
                    // body-credit ack, and for an idle connection, it only
                    // means the peer is done: no new streams open, and
                    // would-block lets the received data still complete.
                    if (entry.h2.hasIncompleteRemoteStreams())
                        return error.FetchResponseTruncated;
                    entry.remote_eof = true;
                    entry.h2.closeWithoutPeerGoaway();
                    return error.Http2WouldBlock;
                },
                .frame => |*frame| {
                    defer frame.deinit();
                    entry.touch(try monotonicNowNs());
                    const maybe_completion = entry.h2.processEventFrame(&entry.outgoing.writer, frame) catch |err|
                        return entry.mapOutgoingWriteError(err);
                    if (maybe_completion) |completion| {
                        var owned_completion = completion;
                        addConnectionWireBytes(&owned_completion, entry);
                        try entry.flushOutgoing();
                        return owned_completion;
                    }
                    try entry.flushOutgoing();
                    frames_without_event += 1;
                    if (frames_without_event > http2.max_frames_without_event_per_read)
                        return error.Http2FrameProgressLimitExceeded;
                },
            }
        }
    }

    pub fn cancelStream(self: *Pool, stream: StreamHandle) !void {
        stream.entry.h2.cancelStream(&stream.entry.outgoing.writer, stream.stream_id) catch |err|
            return stream.entry.mapOutgoingWriteError(err);
        try stream.entry.flushOutgoing();
        stream.entry.touch(try monotonicNowNs());
        _ = self;
    }

    pub fn ackReceivedData(
        self: *Pool,
        entry: *Entry,
        stream_id: u32,
        flow_credit: usize,
        update_stream: bool,
    ) !?http2.Event {
        _ = self;
        var maybe_event = entry.h2.ackReceivedData(&entry.outgoing.writer, stream_id, flow_credit, update_stream) catch |err|
            return entry.mapOutgoingWriteError(err);
        if (maybe_event) |*event|
            addConnectionWireBytes(event, entry);
        try entry.flushOutgoing();
        entry.touch(try monotonicNowNs());
        return maybe_event;
    }

    pub fn removeEntryWithDriver(
        self: *Pool,
        entry: *Entry,
        data_driver: *data_io.Driver,
    ) void {
        self.removeWithDriver(entry, data_driver);
    }

    fn addConnectionWireBytes(event: *http2.Event, entry: *Entry) void {
        const wire_bytes = entry.wire.takeWireBytes();
        // The BIO counts TLS record bytes at the connection boundary, and one
        // record can carry frames of several streams, so ciphertext has no
        // exact per-stream split. Charging each delta to the event being
        // returned keeps the connection's total conserved.
        //
        // The overwrite is unconditional. The codec fills terminal events
        // with its own per-stream plaintext counter, a different unit, and
        // keeping it on a zero delta, as when a deferred `.end` follows right
        // after the head took the delta, would bill that plaintext on top of
        // the ciphertext already charged: about twice the real bytes per
        // fetch. `billed_bytes` on terminal events is a third unit, the HTTP
        // payload, and stays untouched.
        switch (event.*) {
            .head => |*head| head.result.wire_bytes = wire_bytes,
            .progress => |*progress| progress.wire_bytes = wire_bytes,
            .body_chunk => |*body| body.wire_bytes = wire_bytes,
            .end => |*end| end.wire_bytes = wire_bytes,
            .failure => |*failure| failure.wire_bytes = wire_bytes,
        }
    }

    fn evictExpiredIdleWithDriver(
        self: *Pool,
        now_ns: u64,
        data_driver: ?*data_io.Driver,
    ) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (!entry.shouldRemoveIdle(now_ns, self.config)) {
                index += 1;
                continue;
            }
            self.removeWithDriver(entry, data_driver);
        }
    }

    pub fn hasEntries(self: *const Pool) bool {
        return self.entries.items.len != 0;
    }

    pub fn entryLifecycleDeadlineNs(self: *const Pool, entry: *const Entry) u64 {
        return lifecycleDeadlineNs(entry.created_mono_ns, entry.last_active_mono_ns, self.config);
    }

    pub fn hasOutgoing(self: *const Pool) bool {
        for (self.entries.items) |entry| {
            if (entry.hasOutgoing())
                return true;
        }
        return false;
    }

    fn find(
        self: *Pool,
        plan: *const RequestPlan,
        config: TransportConfig,
        now_ns: u64,
    ) ?*Entry {
        for (self.entries.items) |entry| {
            if (!entry.canReuse(now_ns, self.config))
                continue;
            if (entry.key.matches(plan, config))
                return entry;
        }
        return null;
    }

    fn evictLeastRecentlyUsedIdleWithDriver(self: *Pool, data_driver: ?*data_io.Driver) void {
        var victim: ?*Entry = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.entries.items) |entry| {
            if (entry.h2.hasActiveStreams() or entry.hasOutgoing() or entry.last_used >= oldest)
                continue;
            oldest = entry.last_used;
            victim = entry;
        }
        if (victim) |entry|
            self.removeWithDriver(entry, data_driver);
    }

    fn removeWithDriver(self: *Pool, target: *Entry, data_driver: ?*data_io.Driver) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry != target)
                continue;
            _ = self.entries.orderedRemove(index);
            if (data_driver) |driver| {
                if (target.bioTls()) |bio| {
                    if (!driver.cancelConnectionForClose(bio)) {
                        // The cancel is unconfirmed on a live ring: kernel
                        // SQEs may still reference the connection's buffers.
                        // The driver has quarantined the connection and owns
                        // its teardown, so only the rest of the entry goes.
                        target.destroyPreservingWire(self.allocator);
                        return;
                    }
                }
            }
            target.destroy(self.allocator);
            return;
        }
    }
};

/// The writer the codec sends frames into, buffered up to `max_bytes` so a
/// peer that stops reading cannot grow it without bound. A write past the cap
/// or a failed allocation fails with `WriteFailed` and sets a flag that
/// `Entry.mapOutgoingWriteError` turns into the real error.
pub const BoundedOutgoing = struct {
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,
    max_bytes: usize,
    hit_limit: bool = false,
    hit_oom: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) BoundedOutgoing {
        return .{
            .allocator = allocator,
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *BoundedOutgoing) void {
        self.allocator.free(self.writer.buffer);
        self.* = undefined;
    }

    fn clearRetainingCapacity(self: *BoundedOutgoing) void {
        self.writer.end = 0;
    }

    pub fn written(self: *BoundedOutgoing) []u8 {
        return self.writer.buffered();
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = noopFlush,
        .rebase = rebase,
    };

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BoundedOutgoing = @fieldParentPtr("writer", writer);
        const incoming = countSplatChecked(data, splat) catch return self.failLimit();
        if (incoming > self.max_bytes -| writer.end)
            return self.failLimit();
        const desired_capacity = writer.end + incoming;

        var list = self.toArrayList();
        defer self.setArrayList(list);
        list.ensureTotalCapacityPrecise(self.allocator, desired_capacity) catch |err| switch (err) {
            error.OutOfMemory => return self.failOom(),
        };
        for (data[0 .. data.len - 1]) |bytes|
            list.appendSliceAssumeCapacity(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_|
            list.appendSliceAssumeCapacity(pattern);
        return incoming;
    }

    fn rebase(writer: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        _ = preserve;
        const self: *BoundedOutgoing = @fieldParentPtr("writer", writer);
        if (minimum_len > self.max_bytes -| writer.end)
            return self.failLimit();
        const desired_capacity = writer.end + minimum_len;
        var list = self.toArrayList();
        defer self.setArrayList(list);
        list.ensureTotalCapacityPrecise(self.allocator, desired_capacity) catch |err| switch (err) {
            error.OutOfMemory => return self.failOom(),
        };
    }

    fn failLimit(self: *BoundedOutgoing) std.Io.Writer.Error {
        self.hit_limit = true;
        return error.WriteFailed;
    }

    fn failOom(self: *BoundedOutgoing) std.Io.Writer.Error {
        self.hit_oom = true;
        return error.WriteFailed;
    }

    fn toArrayList(self: *BoundedOutgoing) std.ArrayListUnmanaged(u8) {
        const result: std.ArrayListUnmanaged(u8) = .{
            .items = self.writer.buffer[0..self.writer.end],
            .capacity = self.writer.buffer.len,
        };
        self.writer.buffer = &.{};
        self.writer.end = 0;
        return result;
    }

    fn setArrayList(self: *BoundedOutgoing, list: std.ArrayListUnmanaged(u8)) void {
        self.writer.buffer = list.allocatedSlice();
        self.writer.end = list.items.len;
    }
};

// The codec's flushes do nothing here. `Entry.flushOutgoing` moves the buffer
// to the socket as far as the socket accepts, so the owner thread never
// blocks on a write.
fn noopFlush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = writer;
}

fn countSplatChecked(data: []const []const u8, splat: usize) !usize {
    var total: usize = 0;
    for (data[0 .. data.len - 1]) |bytes|
        total = try std.math.add(usize, total, bytes.len);
    const pattern_total = try std.math.mul(usize, data[data.len - 1].len, splat);
    return try std.math.add(usize, total, pattern_total);
}

pub const Entry = struct {
    key: Key,
    wire: HttpConnection,
    h2: http2.Connection,
    frame_reader: http2.FrameReader,
    outgoing: BoundedOutgoing,
    outgoing_flush_offset: usize = 0,
    // SSL_write can ask for read readiness, so the owner tracks the last
    // blocked direction instead of polling for POLLOUT on every flush.
    outgoing_wait: ?IoInterest = null,
    last_used: u64 = 0,
    opened_once: bool = false,
    created_mono_ns: u64,
    last_active_mono_ns: u64,
    // The peer's EOF has been read. Watchers must stop polling a
    // level-triggered socket at EOF for read, or the owner spins; deadlines
    // still bound the completions that wait on body-credit acks.
    remote_eof: bool = false,
    // Owner-thread scratch: this entry's index in the watch list being
    // built, so the builder maps pending requests to entries in one pass.
    watch_scratch: usize = 0,

    pub fn connectBio(
        allocator: std.mem.Allocator,
        plan: *const RequestPlan,
        config: TransportConfig,
        dns_cache: *DnsCache,
        readiness_driver: *readiness.Driver,
        data_driver: *data_io.Driver,
    ) !BioConnectOutcome {
        if (plan.target.protocol != .tls)
            return error.Http2UnsupportedScheme;
        const policy = EgressPolicy{
            .allow_plain_http = config.allow_plain_http,
            .allow_private_networks = config.allow_private_networks,
        };
        var target = try policy.resolveRequestTargetUntil(
            allocator,
            dns_cache,
            plan.target,
            config.request_deadline_mono_ns,
        );
        defer target.deinit(allocator);

        // The handshake uses the stall deadline the engine refreshes on
        // progress, so `Config.stallDeadlineFromNow` stays the one source of
        // the idle-timeout rule.
        const deadline_mono_ns = config.stallDeadlineFromNow(try readiness.monotonicNowNs());
        var stream = try connectStreamWithReadiness(
            target.connect_addresses,
            deadline_mono_ns,
            readiness_driver,
            null,
            .{ .request_deadline_mono_ns = config.request_deadline_mono_ns },
        );
        var stream_owned = true;
        errdefer if (stream_owned)
            stream.close();
        var session_key_buffer: [transport.tls.max_session_key_bytes]u8 = undefined;
        var bio = try TlsBioTransport.createUnhandshaken(
            allocator,
            stream,
            target.tls_server_name,
            config.insecure_tls,
            // This connect speculates on HTTP/2. Offering http/1.1 as well
            // lets the engine learn which origins lack HTTP/2 and send their
            // later requests straight to HTTP/1.
            .h2_http_1_1,
            config.tls_ciphertext_buffer_bytes,
            transport.tls.buildSessionKey(
                &session_key_buffer,
                config.pool_security_cell_id,
                config.pool_policy_id,
                .h2_http_1_1,
                target.tls_server_name,
                target.port,
            ),
        );
        stream_owned = false;
        var bio_owned = true;
        errdefer if (bio_owned) {
            // An unconfirmed cancel quarantines the transport and hands its
            // teardown to the driver; a deinit here would free it twice and
            // pull its buffers out from under kernel SQEs.
            if (data_driver.cancelConnection(bio))
                bio.deinit();
        };

        while (true) {
            switch (try bio.handshakeStep()) {
                .done => |protocol| {
                    if (!data_driver.cancelConnection(bio)) {
                        // The connection cannot move to the owner thread
                        // while kernel I/O on this driver still targets its
                        // buffers; the driver quarantined it and owns its
                        // teardown.
                        bio_owned = false;
                        return error.EgressDataCancelUnconfirmed;
                    }
                    const out = bio;
                    bio_owned = false;
                    return if (protocol == .h2)
                        .{ .h2 = .{ .tls_bio = out } }
                    else
                        .{ .h1 = .{ .tls_bio_direct = out } };
                },
                .wait => |interest| {
                    var context: u8 = 0;
                    switch (try data_driver.wait(&.{.{
                        .context = &context,
                        .connection = bio,
                        .deadline_mono_ns = deadline_mono_ns,
                        .want_read = interest == .read,
                        .want_write = interest == .write or bio.hasCiphertextToSend(),
                    }}, null)) {
                        .ready => continue,
                        .failed => |failure| return failure.err,
                        .expired => {
                            if (config.requestDeadlineExpiredAt(data_io.monotonicNowNs() catch deadline_mono_ns))
                                return error.FetchRequestDeadlineExceeded;
                            return error.TlsHandshakeTimeout;
                        },
                        .wake, .tick => continue,
                    }
                },
            }
        }
    }

    fn createFromConnection(
        allocator: std.mem.Allocator,
        plan: *const RequestPlan,
        config: TransportConfig,
        wire: HttpConnection,
        now_ns: u64,
    ) !*Entry {
        var key = try Key.init(allocator, plan, config);
        errdefer key.deinit(allocator);
        std.debug.assert(wire.applicationProtocol() == .h2);
        var h2_connection = try http2.Connection.initWithLimits(allocator, key.h2_limits);
        errdefer h2_connection.deinit();
        const entry = try allocator.create(Entry);
        entry.* = .{
            .key = key,
            .wire = wire,
            .h2 = h2_connection,
            .frame_reader = http2.FrameReader.init(allocator),
            .outgoing = .init(allocator, key.max_outgoing_buffer_bytes),
            .created_mono_ns = now_ns,
            .last_active_mono_ns = now_ns,
        };
        return entry;
    }

    fn destroy(self: *Entry, allocator: std.mem.Allocator) void {
        self.outgoing.deinit();
        self.frame_reader.deinit();
        self.h2.deinit();
        self.wire.deinit();
        self.key.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Teardown for an entry whose connection the data driver quarantined.
    /// Kernel SQEs may still reference the connection's buffers and the
    /// driver owns its deinit, so everything except the connection goes.
    fn destroyPreservingWire(self: *Entry, allocator: std.mem.Allocator) void {
        self.outgoing.deinit();
        self.frame_reader.deinit();
        self.h2.deinit();
        self.key.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn hasOutgoing(self: *const Entry) bool {
        return self.outgoing_flush_offset < self.outgoing.writer.end;
    }

    pub fn wantsOutgoingRead(self: *const Entry) bool {
        return self.hasOutgoing() and self.outgoing_wait == .read;
    }

    pub fn wantsOutgoingWrite(self: *const Entry) bool {
        return self.hasOutgoing() and self.outgoing_wait != .read;
    }

    pub fn bioTls(self: *Entry) ?*TlsBioTransport {
        return switch (self.wire) {
            .tls_bio => |bio| bio,
            else => null,
        };
    }

    pub fn flushOutgoing(self: *Entry) !void {
        try flushOutgoingBuffer(&self.outgoing, &self.outgoing_flush_offset, &self.outgoing_wait, &self.wire);
    }

    pub fn touch(self: *Entry, now_ns: u64) void {
        self.last_active_mono_ns = now_ns;
    }

    pub fn isIdle(self: *const Entry) bool {
        return !self.h2.hasActiveStreams() and !self.hasOutgoing();
    }

    fn canReuse(self: *const Entry, now_ns: u64, config: Config) bool {
        if (self.h2.closing or !self.h2.canOpenStream())
            return false;
        if (config.max_connection_age_ns != 0 and elapsedSince(self.created_mono_ns, now_ns) >= config.max_connection_age_ns)
            return false;
        return true;
    }

    fn shouldRemoveIdle(self: *const Entry, now_ns: u64, config: Config) bool {
        if (!self.isIdle())
            return false;
        if (self.h2.closing)
            return true;
        return lifecycleDeadlineNs(self.created_mono_ns, self.last_active_mono_ns, config) <= now_ns;
    }

    fn mapOutgoingWriteError(self: *Entry, err: anyerror) anyerror {
        if (err == error.WriteFailed and self.outgoing.hit_limit) {
            self.outgoing.hit_limit = false;
            return error.Http2EgressWriteBufferExceeded;
        }
        if (err == error.WriteFailed and self.outgoing.hit_oom) {
            self.outgoing.hit_oom = false;
            return error.OutOfMemory;
        }
        return err;
    }
};

// The same clock as the readiness and data drivers, which receive the pool's
// entry deadlines as wait deadlines.
fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

pub fn lifecycleDeadlineNs(created_mono_ns: u64, last_active_mono_ns: u64, config: Config) u64 {
    var deadline: u64 = std.math.maxInt(u64);
    if (config.idle_timeout_ns != 0)
        deadline = @min(deadline, addNsSaturating(last_active_mono_ns, config.idle_timeout_ns));
    if (config.max_connection_age_ns != 0)
        deadline = @min(deadline, addNsSaturating(created_mono_ns, config.max_connection_age_ns));
    return deadline;
}

fn addNsSaturating(base: u64, delta: u64) u64 {
    return std.math.add(u64, base, delta) catch std.math.maxInt(u64);
}

fn elapsedSince(start_ns: u64, now_ns: u64) u64 {
    return now_ns -| start_ns;
}

pub fn flushOutgoingBuffer(outgoing: *BoundedOutgoing, flush_offset: *usize, outgoing_wait: *?IoInterest, wire: anytype) !void {
    while (flush_offset.* < outgoing.writer.end) {
        const pending = outgoing.writer.buffer[flush_offset.*..outgoing.writer.end];
        switch (try wire.writeStep(pending)) {
            .ready => |written| {
                if (written == 0)
                    return error.FetchWriteFailed;
                outgoing_wait.* = null;
                flush_offset.* += written;
            },
            .wait => |interest| {
                outgoing_wait.* = interest;
                compactOutgoing(outgoing, flush_offset);
                return;
            },
            .eof => return error.FetchWriteFailed,
        }
    }
    outgoing.clearRetainingCapacity();
    flush_offset.* = 0;
    outgoing_wait.* = null;
}

fn compactOutgoing(outgoing: *BoundedOutgoing, flush_offset: *usize) void {
    if (flush_offset.* == 0)
        return;
    if (flush_offset.* == outgoing.writer.end) {
        outgoing.clearRetainingCapacity();
        flush_offset.* = 0;
        return;
    }
    if (flush_offset.* < 4096 and flush_offset.* * 2 < outgoing.writer.end)
        return;
    const remaining = outgoing.writer.buffer[flush_offset.*..outgoing.writer.end];
    std.mem.copyForwards(u8, outgoing.writer.buffer[0..remaining.len], remaining);
    outgoing.writer.end = remaining.len;
    flush_offset.* = 0;
}

pub const Key = struct {
    authority_host_lower: []u8,
    port: u16,
    insecure_tls: bool,
    allow_private_networks: bool,
    h2_limits: http2.Limits,
    max_outgoing_buffer_bytes: usize,
    tls_ciphertext_buffer_bytes: usize,
    pool_security_cell_id: PoolIsolationId,
    pool_policy_id: PoolIsolationId,

    pub fn init(
        allocator: std.mem.Allocator,
        plan: *const RequestPlan,
        config: TransportConfig,
    ) !Key {
        const host = try allocator.dupe(u8, plan.target.authority_host);
        errdefer allocator.free(host);
        _ = std.ascii.lowerString(host, host);
        const h2_limits = try config.http2Limits().normalized();
        return .{
            .authority_host_lower = host,
            .port = plan.target.port,
            .insecure_tls = config.insecure_tls,
            .allow_private_networks = config.allow_private_networks,
            .h2_limits = h2_limits,
            .max_outgoing_buffer_bytes = config.http2_max_outgoing_buffer_bytes,
            .tls_ciphertext_buffer_bytes = config.tls_ciphertext_buffer_bytes,
            .pool_security_cell_id = config.pool_security_cell_id,
            .pool_policy_id = config.pool_policy_id,
        };
    }

    pub fn deinit(self: *Key, allocator: std.mem.Allocator) void {
        allocator.free(self.authority_host_lower);
        self.* = undefined;
    }

    pub fn matches(self: Key, plan: *const RequestPlan, config: TransportConfig) bool {
        const h2_limits = config.http2Limits().normalized() catch return false;
        return self.port == plan.target.port and
            self.insecure_tls == config.insecure_tls and
            self.allow_private_networks == config.allow_private_networks and
            limitsEqual(self.h2_limits, h2_limits) and
            self.max_outgoing_buffer_bytes == config.http2_max_outgoing_buffer_bytes and
            self.tls_ciphertext_buffer_bytes == config.tls_ciphertext_buffer_bytes and
            std.mem.eql(u8, &self.pool_security_cell_id, &config.pool_security_cell_id) and
            std.mem.eql(u8, &self.pool_policy_id, &config.pool_policy_id) and
            std.ascii.eqlIgnoreCase(self.authority_host_lower, plan.target.authority_host);
    }
};

fn limitsEqual(a: http2.Limits, b: http2.Limits) bool {
    return a.max_active_streams == b.max_active_streams and
        a.stream_receive_window == b.stream_receive_window and
        a.connection_receive_window == b.connection_receive_window and
        a.receive_window_update_threshold == b.receive_window_update_threshold and
        a.max_pending_body_credit_per_stream == b.max_pending_body_credit_per_stream and
        a.max_pending_body_credit_per_connection == b.max_pending_body_credit_per_connection;
}
