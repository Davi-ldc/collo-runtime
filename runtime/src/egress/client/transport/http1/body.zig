//! HTTP/1 response body continuation: after the exchange publishes the head,
//! it streams the framed body from the connection into the fetch body pipe
//! and returns the connection to the pool when the body ended cleanly.
//!
//! A continuation runs on the owner thread and never blocks it. A read that
//! would block unwinds with the cancel probe's would-block error, consumer
//! backpressure returns `paused`, and an exhausted `DriveBudget` returns
//! `yielded`. The budget is checked before each socket read, so a yield never
//! leaves read bytes unappended, and input a paused pump has not taken stays
//! buffered (`pending_input` or the chunked decoder's output) for the next
//! step. Meters are absolute totals for the whole redirect chain.

const std = @import("std");
const accounting = @import("collo_egress_accounting");
const core = @import("collo_egress_core");

const cancel_probe_mod = @import("../cancel_probe.zig");
const config_mod = @import("../config.zig");
const http1_client = @import("root.zig");
const connection_mod = @import("../connection.zig");
const http1 = @import("protocol/root.zig");
const http1_wire = @import("wire.zig");

const body_credit = core.body_credit;
const decompress = core.decompress;
const fetch_body = core.fetch_body;
const stream_pump = core.stream_pump;

const CancelProbe = cancel_probe_mod.CancelProbe;
const Config = config_mod.Config;
const HttpConnection = connection_mod.HttpConnection;
const OwnedResponseHead = http1_wire.OwnedResponseHead;
const readConnectionChunk = http1_wire.readConnectionChunk;

/// Size of the read buffer each continuation leases from the pool's
/// freelist.
pub const continuation_read_buffer_bytes: usize = 64 * 1024;

/// First and smallest allocation of the identity direct-read path: small
/// enough that a slow stream's per-read allocation stays cheap, and four
/// doublings from the full read buffer for bulk streams.
pub const initial_direct_read_bytes: usize = 4 * 1024;

/// Fairness quantum for one drive of a continuation on the single owner
/// thread. The body loop keeps reading while the socket produces, so without
/// a bound a fast origin with a large body and ample consumer credit would
/// hold the thread from head to EOF while every other request waits. HTTP/2
/// bounds its read pass with the codec's `max_frames_without_event_per_read`;
/// HTTP/1 stops a drive after `drive_budget_max_reads` socket reads or
/// `drive_budget_max_bytes` delivered, whichever comes first. Sixteen reads
/// cover the direct-read ramp (4 KiB doubling to the 64 KiB buffer in five
/// reads) plus a run of full reads, and 256 KiB is four full read buffers.
/// An exhausted budget makes the step return `Step.yielded`: the
/// continuation waits on nothing, so it stays runnable with no deadline, and
/// the owner returns to it on its next drive pass. The owner also bounds each
/// whole pass with `H1TurnBudget` in engine/h2_engine.zig, which documents
/// how the two budgets share the thread between HTTP/1 and HTTP/2.
pub const drive_budget_max_reads: usize = 16;
pub const drive_budget_max_bytes: usize = 256 * 1024;

pub const DriveBudget = struct {
    reads_left: usize = drive_budget_max_reads,
    bytes_left: usize = drive_budget_max_bytes,

    /// Checked before touching the socket, never after a read, so exhaustion
    /// cannot strand bytes read but not yet appended: the step hands
    /// everything already read to the pump before it reaches the next check.
    fn beginRead(self: *const DriveBudget) error{Http1BodyYielded}!void {
        if (self.reads_left == 0 or self.bytes_left == 0)
            return error.Http1BodyYielded;
    }

    fn charge(self: *DriveBudget, bytes: usize) void {
        self.reads_left -|= 1;
        self.bytes_left -|= bytes;
    }
};

pub const BodyReadyEvent = union(enum) {
    generic,
    token: ReadyToken,
};

pub const ReadyToken = struct {
    ptr: *anyopaque,
    generation: u64,
};

pub const Http1BodyReadyFn = *const fn (?*anyopaque, BodyReadyEvent) void;

pub const Continuation = struct {
    allocator: std.mem.Allocator,
    connection: HttpConnection,
    response: OwnedResponseHead,
    wire_bytes: accounting.Bytes,
    /// Ciphertext cost of the whole redirect chain, seeded by the exchange;
    /// each meter fold adds the connection's BIO delta since the last take.
    /// It stays flat on plain and `.fd_tls` connections, which cannot observe
    /// ciphertext.
    cost_bytes: u64,
    source_id: u64,
    head_request: bool,
    encoding: decompress.Encoding,
    pump: stream_pump.Pump,
    config: Config,
    body: *fetch_body.Body,
    ready_ctx: ?*anyopaque,
    ready_fn: Http1BodyReadyFn,
    ready_event: BodyReadyEvent,
    /// Socket read buffer, leased from the pool's freelist at init and
    /// returned at deinit. `pending_input` borrows from it, or from the
    /// response's owned wire bytes at startup, so a read needs no
    /// intermediate copy. Identity bodies on the direct route skip it and
    /// read into right-sized owned allocations.
    read_buffer: []u8,
    read_buffer_pool: *http1_client.Http1Pool,
    pending_input: []const u8 = &.{},
    pending_offset: usize = 0,
    /// Allocation cap for the identity direct-read path. It doubles on a
    /// filled read and falls back to the observed length, never below
    /// `initial_direct_read_bytes`, on a short one. That bounds the unused
    /// allocation at about twice the stream's real arrival size, where a
    /// fixed 64 KiB per read would waste most of it on a slow body.
    direct_read_hint: usize = initial_direct_read_bytes,
    /// Chooses between the two identity read routes. On a drip origin, with
    /// reads far below `initial_direct_read_bytes`, the direct route would
    /// pay an allocation and a shrink on every read, more than the buffered
    /// route's one exact-size copy. A direct read under half that floor and
    /// short of its target switches to the buffered route; a buffered read
    /// of at least `initial_direct_read_bytes` switches back for bulk
    /// streams.
    direct_read_enabled: bool = true,
    state: BodyState,
    resume_requested: bool = false,
    /// Hand-back ticket for the shared pool; present only when the response
    /// head allows reuse. Redeemed after a clean framed completion,
    /// discarded on every failure path.
    pooled_return: ?http1_client.ConnectionReturn = null,
    connection_returned: bool = false,
    clean_for_pool: bool = true,

    const BodyState = union(enum) {
        content_length: usize,
        close_delimited,
        chunked: ChunkedState,
        finished,
    };

    const ChunkedState = struct {
        decoder: http1.ChunkedDecoder = .{},
        decoded_body: std.array_list.Aligned(u8, null) = .empty,
        /// Bytes of `decoded_body` already appended to the fetch body; the
        /// live remainder is `decoded_body.items[consumed..]`. Compacting
        /// after every partial append would cost O(n²) over a backpressured
        /// burst, so compaction waits for the next decode (`compactForRefill`).
        /// That keeps `decoded_body.items.len` equal to the remainder whenever
        /// the decoder checks its output limit.
        consumed: usize = 0,
        done: bool = false,

        fn remainder(self: *const ChunkedState) []const u8 {
            return self.decoded_body.items[self.consumed..];
        }

        fn advance(self: *ChunkedState, bytes: usize) void {
            self.consumed += bytes;
            std.debug.assert(self.consumed <= self.decoded_body.items.len);
            if (self.consumed == self.decoded_body.items.len) {
                self.decoded_body.clearRetainingCapacity();
                self.consumed = 0;
            }
        }

        /// Compact once per wire-decode instead of once per pump append.
        fn compactForRefill(self: *ChunkedState) void {
            if (self.consumed == 0)
                return;
            const remaining = self.decoded_body.items.len - self.consumed;
            std.mem.copyForwards(
                u8,
                self.decoded_body.items[0..remaining],
                self.decoded_body.items[self.consumed..],
            );
            self.decoded_body.shrinkRetainingCapacity(remaining);
            self.consumed = 0;
        }

        fn deinit(self: *ChunkedState, allocator: std.mem.Allocator) void {
            self.decoded_body.deinit(allocator);
            self.* = undefined;
        }
    };

    pub const Step = enum {
        done,
        paused,
        /// The drive budget ran out. The continuation waits on nothing and
        /// arms no deadline, so the owner must drive it again after its other
        /// runnable requests and watches have had their turn.
        yielded,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        read_buffer_pool: *http1_client.Http1Pool,
        connection: HttpConnection,
        response: OwnedResponseHead,
        wire_bytes: accounting.Bytes,
        cost_bytes: u64,
        source_id: u64,
        head_request: bool,
        encoding: decompress.Encoding,
        pump_limits: stream_pump.Limits,
        config: Config,
        body: *fetch_body.Body,
        ready_ctx: ?*anyopaque,
        ready_fn: Http1BodyReadyFn,
        ready_event: BodyReadyEvent,
        pooled_return: ?http1_client.ConnectionReturn,
    ) !*Continuation {
        var pump = try stream_pump.Pump.initWithLimits(encoding, pump_limits);
        errdefer pump.deinit(allocator);
        const read_buffer = try read_buffer_pool.acquireBodyReadBuffer();
        errdefer read_buffer_pool.releaseBodyReadBuffer(read_buffer);
        const state: BodyState = if (head_request or response.head.body_framing == .none)
            .finished
        else switch (response.head.body_framing) {
            .none => .finished,
            .content_length => blk: {
                if (response.head.post_head_bytes.len > response.head.content_length)
                    return error.InvalidResponseBodyFraming;
                if (encoding == .identity and response.head.content_length > pump_limits.max_decoded_bytes)
                    return error.FetchResponseTooLarge;
                break :blk .{ .content_length = response.head.content_length - response.head.initial_body_bytes.len };
            },
            .close_delimited => .close_delimited,
            .http1_chunked => .{ .chunked = .{} },
        };
        const continuation = try allocator.create(Continuation);
        body.retain();
        continuation.* = .{
            .allocator = allocator,
            .connection = connection,
            .response = response,
            .wire_bytes = wire_bytes,
            .cost_bytes = cost_bytes,
            .source_id = source_id,
            .head_request = head_request,
            .encoding = encoding,
            .pump = pump,
            .config = config,
            .body = body,
            .ready_ctx = ready_ctx,
            .ready_fn = ready_fn,
            .ready_event = ready_event,
            .read_buffer = read_buffer,
            .read_buffer_pool = read_buffer_pool,
            .pending_input = response.head.initial_body_bytes,
            .state = state,
            .pooled_return = pooled_return,
        };
        return continuation;
    }

    /// Returns the connection to the pool after a clean completion: the body
    /// ended by its own framing (close-delimited bodies carry no ticket)
    /// without bare-LF leniency in its chunk lines, and no byte was read past
    /// it. Otherwise deinit closes the connection.
    pub fn returnConnectionIfReusable(self: *Continuation) void {
        var ticket = self.pooled_return orelse return;
        self.pooled_return = null;
        if (!self.clean_for_pool or self.state != .finished or self.pendingSlice().len != 0) {
            ticket.discard();
            return;
        }
        const connection = self.connection;
        self.connection = undefined;
        self.connection_returned = true;
        ticket.give(connection);
    }

    /// Folds the meters into the fetch body as totals for the whole redirect
    /// chain: billed plaintext per direction, and ciphertext cost including
    /// this connection's latest BIO delta. After the connection went back to
    /// the pool the take is skipped, since the pool owns it.
    pub fn foldMetersIntoBody(self: *Continuation) void {
        if (!self.connection_returned)
            self.cost_bytes +|= self.connection.takeWireBytes().total();
        self.body.setEgressMeters(.{
            .billed_sent = self.wire_bytes.sent,
            .billed_received = self.wire_bytes.received,
            .cost = self.cost_bytes,
        });
    }

    pub fn step(self: *Continuation, cancel_probe: CancelProbe, budget: *DriveBudget) !Step {
        return self.runUntilBlocked(cancel_probe, budget) catch |err| switch (err) {
            error.Http1BodyPaused => return .paused,
            error.Http1BodyYielded => return .yielded,
            else => return err,
        };
    }

    pub fn failAndDeinit(self: *Continuation, message: []const u8) void {
        // A failed fetch is billed for what crossed the wire, so the meters,
        // including this connection's final ciphertext delta, are folded
        // before the failure reaches the consumer. The HTTP/2 path folds the
        // same way before failing a published body.
        self.foldMetersIntoBody();
        failFetchBody(self.body, self.allocator, message);
        self.ready_fn(self.ready_ctx, self.ready_event);
        self.deinit();
    }

    pub fn deinit(self: *Continuation) void {
        const allocator = self.allocator;
        self.body.releaseAfterQueuedResourcesReleased(allocator);
        switch (self.state) {
            .chunked => |*chunked| chunked.deinit(allocator),
            else => {},
        }
        self.pump.deinit(allocator);
        self.response.deinit();
        if (self.pooled_return) |*ticket|
            ticket.discard();
        if (!self.connection_returned)
            self.connection.deinit();
        self.read_buffer_pool.releaseBodyReadBuffer(self.read_buffer);
        allocator.destroy(self);
    }

    fn runUntilBlocked(self: *Continuation, cancel_probe: CancelProbe, budget: *DriveBudget) !Step {
        while (true) {
            if (cancel_probe.isCanceled())
                return error.FetchAborted;
            if (try self.drainPendingInput())
                continue;
            switch (self.state) {
                .finished => return try self.finishPumpAvailable(),
                .content_length => |remaining_wire| {
                    if (remaining_wire == 0) {
                        self.state = .finished;
                        continue;
                    }
                    if (self.encoding == .identity) {
                        if (try self.stepIdentityDirect(remaining_wire, cancel_probe, budget)) |read_len| {
                            if (read_len == 0)
                                return error.FetchResponseTruncated;
                            self.state.content_length = remaining_wire - read_len;
                            continue;
                        }
                        // Null means the decoded budget is spent or the drip
                        // route is active. The buffered read below covers
                        // both; with a spent budget, its pump append tells a
                        // body ending exactly at the budget from one that
                        // exceeds it.
                    }
                    try budget.beginRead();
                    const read_len = try readConnectionChunk(
                        &self.connection,
                        self.read_buffer[0..@min(self.read_buffer.len, remaining_wire)],
                        self.config,
                        cancel_probe,
                    );
                    budget.charge(read_len);
                    if (read_len == 0)
                        return error.FetchResponseTruncated;
                    // A buffered read this large means bulk arrivals, so the
                    // next read takes the direct route again.
                    if (read_len >= initial_direct_read_bytes)
                        self.direct_read_enabled = true;
                    self.wire_bytes.addReceived(read_len);
                    self.foldMetersIntoBody();
                    self.state.content_length = remaining_wire - read_len;
                    self.setPendingInput(self.read_buffer[0..read_len]);
                },
                .close_delimited => {
                    if (self.encoding == .identity) {
                        if (try self.stepIdentityDirect(self.read_buffer.len, cancel_probe, budget)) |read_len| {
                            if (read_len == 0)
                                self.state = .finished;
                            continue;
                        }
                    }
                    try budget.beginRead();
                    const read_len = try readConnectionChunk(&self.connection, self.read_buffer, self.config, cancel_probe);
                    budget.charge(read_len);
                    if (read_len == 0) {
                        self.state = .finished;
                        continue;
                    }
                    // As in the content-length arm, a large buffered read
                    // returns to the direct route.
                    if (read_len >= initial_direct_read_bytes)
                        self.direct_read_enabled = true;
                    self.wire_bytes.addReceived(read_len);
                    self.foldMetersIntoBody();
                    self.setPendingInput(self.read_buffer[0..read_len]);
                },
                .chunked => |*chunked| {
                    if (try self.drainChunkedDecoded(chunked))
                        continue;
                    if (chunked.done) {
                        if (chunked.decoder.saw_lenient_line_end)
                            self.clean_for_pool = false;
                        chunked.deinit(self.allocator);
                        self.state = .finished;
                        continue;
                    }
                    try budget.beginRead();
                    const read_len = try readConnectionChunk(&self.connection, self.read_buffer, self.config, cancel_probe);
                    budget.charge(read_len);
                    if (read_len == 0)
                        return error.FetchResponseTruncated;
                    self.wire_bytes.addReceived(read_len);
                    self.foldMetersIntoBody();
                    self.setPendingInput(self.read_buffer[0..read_len]);
                },
            }
        }
    }

    /// Direct route for identity bodies: read into a fresh allocation of the
    /// right size and hand it to the body pipe, which takes ownership instead
    /// of copying it. Capacity is probed before the read with the same check
    /// the pump's append makes, so a full queue pauses before reading instead
    /// of holding bytes it cannot append. The pause stays live because the
    /// append that exhausted capacity carried the resume credit
    /// (`resumeCreditFor` in core/stream_pump.zig).
    ///
    /// Returns null when the decoded budget is spent or the drip route is
    /// active; the caller then uses the buffered read, whose pump append tells
    /// a clean EOF exactly at the budget from an over-budget body. Otherwise
    /// returns the wire bytes read, where 0 is EOF and the caller interprets
    /// it by framing.
    fn stepIdentityDirect(self: *Continuation, wire_cap: usize, cancel_probe: CancelProbe, budget: *DriveBudget) !?usize {
        std.debug.assert(self.pendingSlice().len == 0);
        // Drip origins take the buffered route (see `direct_read_enabled`).
        if (!self.direct_read_enabled)
            return null;
        const available = switch (self.pump.identityCapacity(self.body)) {
            .budget_exhausted => return null,
            .paused => return error.Http1BodyPaused,
            .available => |n| n,
        };
        // Checked after the capacity probe so a real pause, woken by its
        // resume credit, takes precedence over a budget yield, which would
        // only be re-driven at once.
        try budget.beginRead();
        // `direct_read_hint` caps the allocation so a slow stream (1 KiB
        // arrivals) does not allocate and free 64 KiB per read, which would
        // cost more than the buffered route's copy. A bulk body reaches the
        // full buffer size within four filled reads and then streams without
        // copies.
        const target = @min(
            @min(available, wire_cap),
            @min(self.read_buffer.len, self.direct_read_hint),
        );
        var owned = try self.allocator.alloc(u8, target);
        errdefer self.allocator.free(owned);
        const read_len = try readConnectionChunk(&self.connection, owned, self.config, cancel_probe);
        budget.charge(read_len);
        if (read_len == 0) {
            self.allocator.free(owned);
            return 0;
        }
        self.direct_read_hint = if (read_len == target)
            @min(self.direct_read_hint *| 2, self.read_buffer.len)
        else
            @max(read_len, initial_direct_read_bytes);
        // A read far below the floor marks a drip origin; switch to the
        // buffered route before the allocate-and-shrink cost repeats.
        if (read_len < initial_direct_read_bytes / 2 and read_len < target)
            self.direct_read_enabled = false;
        self.wire_bytes.addReceived(read_len);
        self.foldMetersIntoBody();
        if (read_len < owned.len) {
            // The allocator usually shrinks in place. A copy across size
            // classes is rare and costs no more than the buffered route's
            // copy of every read.
            owned = try self.allocator.realloc(owned, read_len);
        }
        const result = try self.pump.appendHttp1IdentityOwned(
            self.allocator,
            self.body,
            owned,
            body_credit.h1Resume(self.source_id),
        );
        std.debug.assert(result.consumed == read_len);
        if (result.ready)
            self.ready_fn(self.ready_ctx, self.ready_event);
        return read_len;
    }

    fn drainPendingInput(self: *Continuation) !bool {
        const pending = self.pendingSlice();
        if (pending.len == 0)
            return false;
        switch (self.state) {
            .chunked => |*chunked| {
                // Drop the consumed prefix once per refill, so the decoder's
                // output limit sees only the unconsumed remainder.
                chunked.compactForRefill();
                const limit = if (self.encoding == .identity)
                    self.pump.limits.max_decoded_bytes
                else
                    std.math.maxInt(usize);
                const decoded = try chunked.decoder.decode(
                    self.allocator,
                    pending,
                    &chunked.decoded_body,
                    .{
                        .max_output_bytes = limit,
                        .max_wire_bytes = self.pump.limits.max_encoded_bytes,
                    },
                );
                self.advancePending(decoded.consumed);
                chunked.done = decoded.done;
                if (decoded.done and self.pendingSlice().len != 0)
                    return error.InvalidResponseBodyFraming;
                return decoded.consumed != 0 or chunked.remainder().len != 0 or decoded.done;
            },
            else => {
                const result = try self.pump.appendHttp1DataAvailable(
                    self.allocator,
                    self.body,
                    pending,
                    body_credit.h1Resume(self.source_id),
                );
                if (result.ready)
                    self.ready_fn(self.ready_ctx, self.ready_event);
                self.advancePending(result.consumed);
                if (result.paused)
                    return error.Http1BodyPaused;
                return result.consumed != 0;
            },
        }
    }

    fn drainChunkedDecoded(self: *Continuation, chunked: *ChunkedState) !bool {
        const remainder = chunked.remainder();
        if (remainder.len == 0)
            return false;
        const result = try self.pump.appendHttp1DataAvailable(
            self.allocator,
            self.body,
            remainder,
            body_credit.h1Resume(self.source_id),
        );
        if (result.ready)
            self.ready_fn(self.ready_ctx, self.ready_event);
        // Compaction waits for the next refill (see `ChunkedState.consumed`).
        chunked.advance(result.consumed);
        if (result.paused)
            return error.Http1BodyPaused;
        return result.consumed != 0;
    }

    fn finishPumpAvailable(self: *Continuation) !Step {
        const result = try self.pump.finishHttp1Available(
            self.allocator,
            self.body,
            body_credit.h1Resume(self.source_id),
        );
        if (result.ready)
            self.ready_fn(self.ready_ctx, self.ready_event);
        return if (result.complete) .done else .paused;
    }

    fn pendingSlice(self: *const Continuation) []const u8 {
        return self.pending_input[self.pending_offset..];
    }

    fn setPendingInput(self: *Continuation, bytes: []const u8) void {
        std.debug.assert(self.pendingSlice().len == 0);
        self.pending_input = bytes;
        self.pending_offset = 0;
    }

    fn advancePending(self: *Continuation, consumed: usize) void {
        if (consumed == 0)
            return;
        self.pending_offset += consumed;
        if (self.pending_offset == self.pending_input.len) {
            self.pending_input = &.{};
            self.pending_offset = 0;
        }
    }
};

pub fn failFetchBody(body_pipe: anytype, allocator: std.mem.Allocator, message: []const u8) void {
    _ = body_pipe.fail(allocator, message) catch |err| {
        std.log.warn("failed to mark fetch body failed: {s}", .{@errorName(err)});
        _ = body_pipe.failNoAlloc();
    };
}
