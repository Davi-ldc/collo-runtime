//! HTTP/2 connection pool of one engine. The engine's owner thread keeps it
//! for a run and is the only thread that touches it, so sessions, HPACK
//! state, wire buffers and flow-control windows carry no locks. The owner
//! dials; a wire whose handshake negotiated h2 becomes an entry through
//! `addEntry`, already registered in the owner's data driver, and every
//! removal goes back through that driver (`removeEntry`).
//!
//! An entry serves one origin (`plan.zig:OriginKey`), so no connection state
//! crosses security cells or policies. Its HTTP/2 limits come from the config
//! of the fetch that opened it. Past `max_connection_age_ns` an entry takes
//! no new streams. An idle entry leaves the pool at its idle timeout or
//! maximum age, or at once when it is closing; a full pool evicts its least
//! recently used idle entry. Every connection's codec borrows the engine's
//! one HPACK scratch (`http2.HpackScratch`), which only the owner thread
//! uses, one block at a time.

const std = @import("std");
const data_io = @import("../../io/bio_data.zig");
const http2 = @import("codec/root.zig");
const transport = @import("../root.zig");

const IoInterest = transport.IoInterest;
const OriginKey = transport.request_plan.OriginKey;
const RequestPlan = transport.RequestPlan;
const TransportConfig = transport.Config;
const Wire = transport.Wire;
const monotonicNowNs = transport.config.monotonicNowNs;

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

pub const StreamHandle = struct {
    entry: *Entry,
    stream_id: u32,
    /// True when the stream opened on a session that had served earlier
    /// requests. As in undici and Bun, that is the precondition for retrying,
    /// without the caller noticing, a request whose pooled connection proves
    /// dead.
    reused: bool = false,
};

/// `needs_connection` means no reusable entry exists for the origin and the
/// pool has room for one: the caller dials. `entry_failed` means opening the
/// stream broke the entry, so the caller fails every stream on it and removes
/// it. `failed` fails the request without touching any entry;
/// `error.Http2PoolExhausted` there means every slot holds a busy entry.
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
    /// Borrowed from the engine for the pool's life.
    hpack_scratch: *const http2.HpackScratch,
    entries: std.array_list.Aligned(*Entry, null) = .empty,
    use_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config, hpack_scratch: *const http2.HpackScratch) Pool {
        std.debug.assert(config.max_entries != 0);
        return .{
            .allocator = allocator,
            .config = config,
            .hpack_scratch = hpack_scratch,
        };
    }

    /// Every entry must already have left through `removeEntry`, which
    /// releases its wire from the data driver.
    pub fn deinit(self: *Pool) void {
        std.debug.assert(self.entries.items.len == 0);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Opens a stream for `plan`'s hop on a reusable entry of its origin.
    /// `body` is the hop's request body, borrowed until the stream ends.
    pub fn startRequest(
        self: *Pool,
        plan: *const RequestPlan,
        body: []const u8,
        config: TransportConfig,
        data_driver: *data_io.Driver,
    ) !StartResult {
        const now_ns = try monotonicNowNs();
        self.evictExpiredIdle(now_ns, data_driver);

        if (plan.target.protocol != .tls)
            return .{ .failed = error.Http2UnsupportedScheme };
        // Before an entry is chosen or a dial begins: a head the codec would
        // refuse fails here alone, while a refusal from the entry's encoder
        // would fail every stream sharing it.
        const head = plan.h2RequestHead(body);
        http2.validateRequestHead(head) catch |err|
            return .{ .failed = err };

        const entry = self.find(&plan.origin_key, now_ns) orelse {
            if (self.entries.items.len >= self.config.max_entries) {
                self.evictLeastRecentlyUsedIdle(data_driver);
                if (self.entries.items.len >= self.config.max_entries)
                    return .{ .failed = error.Http2PoolExhausted };
            }
            return .needs_connection;
        };
        return self.openOnEntry(entry, head, config.max_response_body_bytes, now_ns);
    }

    /// Takes `wire`, handshaken with h2 for `key`'s origin and registered in
    /// `data_driver`, as a new entry, and queues the client preface on it at
    /// once: a server may wait for the preface before it sends anything, and
    /// the entry may idle before its first stream, or never get one when
    /// every fetch that waited for it fails first. On error the wire is
    /// released through the driver. Fails with `error.Http2PoolExhausted`
    /// when every slot holds a busy entry.
    pub fn addEntry(
        self: *Pool,
        key: *const OriginKey,
        wire: *Wire,
        config: TransportConfig,
        data_driver: *data_io.Driver,
    ) !*Entry {
        var wire_owned = true;
        errdefer if (wire_owned) releaseWire(data_driver, wire);
        std.debug.assert(wire.protocol == .h2);
        const now_ns = try monotonicNowNs();
        self.evictExpiredIdle(now_ns, data_driver);
        if (self.entries.items.len >= self.config.max_entries) {
            self.evictLeastRecentlyUsedIdle(data_driver);
            if (self.entries.items.len >= self.config.max_entries)
                return error.Http2PoolExhausted;
        }
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const limits = try config.http2Limits().normalized();
        const entry = try Entry.create(self.allocator, key.*, wire, limits, config.http2_max_outgoing_buffer_bytes, self.hpack_scratch, now_ns);
        wire_owned = false;
        errdefer {
            entry.destroyKeepingWire(self.allocator);
            releaseWire(data_driver, wire);
        }
        entry.h2.start(&entry.outgoing.writer) catch |err|
            return entry.mapOutgoingWriteError(err);
        try entry.flushOutgoing();
        entry.last_used = self.nextUseOrder();
        self.entries.appendAssumeCapacity(entry);
        return entry;
    }

    fn openOnEntry(self: *Pool, entry: *Entry, head: http2.RequestHead, max_response_body_bytes: usize, now_ns: u64) StartResult {
        const reused = entry.opened_once;
        entry.opened_once = true;
        const stream_id = entry.h2.openRequest(&entry.outgoing.writer, head, max_response_body_bytes) catch |err|
            return .{ .entry_failed = .{
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
            .stream_id = stream_id,
            .reused = reused,
        } };
    }

    fn nextUseOrder(self: *Pool) u64 {
        self.use_counter +%= 1;
        if (self.use_counter == 0)
            self.use_counter = 1;
        return self.use_counter;
    }

    /// The next event the entry's connection produced from the bytes its wire
    /// holds, or `error.Http2WouldBlock` when they hold no complete event.
    /// The caller owns the event, which may hold a decoded head or a body
    /// chunk. Nothing that can fail runs between producing an event and
    /// returning it, so a failure never drops one: what the event's frame
    /// wrote goes out with the flush that opens the next call, or when the
    /// wire turns writable.
    pub fn readEntryEvent(self: *Pool, entry: *Entry) !http2.Event {
        _ = self;
        try entry.flushOutgoing();
        // Runs before every read, as `Connection.nextUnprocessedStreamFailure`
        // requires of callers that read frames themselves.
        const unprocessed = entry.h2.nextUnprocessedStreamFailure(&entry.outgoing.writer) catch |err|
            return entry.mapOutgoingWriteError(err);
        if (unprocessed) |failure|
            return failure;
        var frames_without_event: usize = 0;
        while (true) {
            var read_result = try entry.frame_reader.readFrom(entry.wire, entry.h2.session.local_settings.max_frame_size);
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
                    const maybe_event = entry.h2.processEventFrame(&entry.outgoing.writer, frame) catch |err|
                        return entry.mapOutgoingWriteError(err);
                    if (maybe_event) |event|
                        return event;
                    try entry.flushOutgoing();
                    frames_without_event += 1;
                    if (frames_without_event > http2.max_frames_without_event_per_read)
                        return error.Http2FrameProgressLimitExceeded;
                },
            }
        }
    }

    pub fn cancelStream(self: *Pool, stream: StreamHandle) !void {
        _ = self;
        stream.entry.h2.cancelStream(&stream.entry.outgoing.writer, stream.stream_id) catch |err|
            return stream.entry.mapOutgoingWriteError(err);
        try stream.entry.flushOutgoing();
        stream.entry.touch(try monotonicNowNs());
    }

    pub fn ackReceivedData(
        self: *Pool,
        entry: *Entry,
        stream_id: u32,
        flow_credit: usize,
        update_stream: bool,
    ) !?http2.Event {
        _ = self;
        const maybe_event = entry.h2.ackReceivedData(&entry.outgoing.writer, stream_id, flow_credit, update_stream) catch |err|
            return entry.mapOutgoingWriteError(err);
        try entry.flushOutgoing();
        entry.touch(try monotonicNowNs());
        return maybe_event;
    }

    /// Takes the entry out of the pool and releases its wire through the
    /// data driver, which keeps a wire whose cancel the kernel has not
    /// confirmed until its terminal completions arrive.
    pub fn removeEntry(self: *Pool, target: *Entry, data_driver: *data_io.Driver) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry != target)
                continue;
            _ = self.entries.orderedRemove(index);
            const wire = target.wire;
            target.destroyKeepingWire(self.allocator);
            releaseWire(data_driver, wire);
            return;
        }
    }

    fn evictExpiredIdle(self: *Pool, now_ns: u64, data_driver: *data_io.Driver) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (!entry.shouldRemoveIdle(now_ns, self.config)) {
                index += 1;
                continue;
            }
            self.removeEntry(entry, data_driver);
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

    fn find(self: *Pool, key: *const OriginKey, now_ns: u64) ?*Entry {
        for (self.entries.items) |entry| {
            if (!entry.canReuse(now_ns, self.config))
                continue;
            if (entry.key.eql(key))
                return entry;
        }
        return null;
    }

    fn evictLeastRecentlyUsedIdle(self: *Pool, data_driver: *data_io.Driver) void {
        var victim: ?*Entry = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.entries.items) |entry| {
            if (entry.h2.hasActiveStreams() or entry.hasOutgoing() or entry.last_used >= oldest)
                continue;
            oldest = entry.last_used;
            victim = entry;
        }
        if (victim) |entry|
            self.removeEntry(entry, data_driver);
    }
};

/// Releases a wire registered in `data_driver`: the driver confirms its
/// cancel and the wire is freed here, or the driver keeps it until the
/// kernel lets go of its buffers and frees it itself.
fn releaseWire(data_driver: *data_io.Driver, wire: *Wire) void {
    if (data_driver.cancelConnectionForClose(wire))
        wire.deinit();
}

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
// to the wire as far as the wire accepts, so the owner thread never blocks on
// a write.
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
    key: OriginKey,
    wire: *Wire,
    h2: http2.Connection,
    frame_reader: http2.FrameReader,
    outgoing: BoundedOutgoing,
    outgoing_flush_offset: usize = 0,
    // SSL_write can ask for read readiness, so the owner tracks the last
    // blocked direction instead of polling for writability on every flush.
    outgoing_wait: ?IoInterest = null,
    last_used: u64 = 0,
    opened_once: bool = false,
    created_mono_ns: u64,
    last_active_mono_ns: u64,
    // The peer's EOF has been read. Watchers must stop reading a wire at
    // EOF, or the owner spins; deadlines still bound the completions that
    // wait on body-credit acks.
    remote_eof: bool = false,
    // Owner-thread scratch: this entry's index in the watch list being
    // built, so the builder maps streams to entries in one pass.
    watch_index: usize = 0,

    fn create(
        allocator: std.mem.Allocator,
        key: OriginKey,
        wire: *Wire,
        limits: http2.Limits,
        max_outgoing_buffer_bytes: usize,
        hpack_scratch: *const http2.HpackScratch,
        now_ns: u64,
    ) !*Entry {
        var h2_connection = try http2.Connection.initWithLimits(allocator, limits, hpack_scratch);
        errdefer h2_connection.deinit();
        const entry = try allocator.create(Entry);
        entry.* = .{
            .key = key,
            .wire = wire,
            .h2 = h2_connection,
            .frame_reader = http2.FrameReader.init(allocator),
            .outgoing = .init(allocator, max_outgoing_buffer_bytes),
            .created_mono_ns = now_ns,
            .last_active_mono_ns = now_ns,
        };
        return entry;
    }

    /// Frees everything but the wire, which the caller releases through the
    /// data driver.
    fn destroyKeepingWire(self: *Entry, allocator: std.mem.Allocator) void {
        self.outgoing.deinit();
        self.frame_reader.deinit();
        self.h2.deinit();
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

    pub fn flushOutgoing(self: *Entry) !void {
        try flushOutgoingBuffer(&self.outgoing, &self.outgoing_flush_offset, &self.outgoing_wait, self.wire);
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
        if (config.max_connection_age_ns != 0 and now_ns -| self.created_mono_ns >= config.max_connection_age_ns)
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

pub fn lifecycleDeadlineNs(created_mono_ns: u64, last_active_mono_ns: u64, config: Config) u64 {
    var deadline: u64 = std.math.maxInt(u64);
    if (config.idle_timeout_ns != 0)
        deadline = @min(deadline, last_active_mono_ns +| config.idle_timeout_ns);
    if (config.max_connection_age_ns != 0)
        deadline = @min(deadline, created_mono_ns +| config.max_connection_age_ns);
    return deadline;
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
