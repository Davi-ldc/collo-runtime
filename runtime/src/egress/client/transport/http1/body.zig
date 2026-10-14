//! HTTP/1 response body continuation: after the exchange publishes the head,
//! it moves the framed body from the wire into the fetch's response queue
//! and returns the wire to the pool when the body ended cleanly.
//!
//! A continuation runs on the owner thread and never blocks it. One `step`
//! consumes only what the wire already holds and returns `.wait` when the
//! wire must hear from the network first, so a step is bounded by one
//! receive, the same grain an HTTP/2 connection advances by, and needs no
//! budget of its own. Consumer backpressure returns `.paused`, and input the
//! paused pump has not taken stays buffered (`pending_input` or the chunked
//! decoder's output) for the next step.

const std = @import("std");
const core = @import("collo_egress_core");

const config_mod = @import("../config.zig");
const http1_client = @import("root.zig");
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const wire_mod = @import("../wire.zig");

const body_credit = core.body_credit;
const decompress = core.decompress;
const stream_pump = core.stream_pump;

const IoInterest = config_mod.IoInterest;
const OwnedResponseHead = message.OwnedResponseHead;
const ResponseQueue = core.ResponseQueue;
const Wire = wire_mod.Wire;

/// Size of the read buffer each continuation leases from the pool's
/// freelist.
pub const continuation_read_buffer_bytes: usize = 64 * 1024;

/// First and smallest allocation of the identity direct-read path: small
/// enough that a slow stream's per-read allocation stays cheap, and four
/// doublings from the full read buffer for bulk streams.
pub const initial_direct_read_bytes: usize = 4 * 1024;

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
    pool: *http1_client.Http1Pool,
    wire: *Wire,
    response: OwnedResponseHead,
    source_id: u64,
    encoding: decompress.Encoding,
    pump: stream_pump.Pump,
    queue: *ResponseQueue,
    ready_ctx: ?*anyopaque,
    ready_fn: Http1BodyReadyFn,
    ready_event: BodyReadyEvent,
    /// Read buffer, leased from the pool's freelist at init and returned at
    /// deinit. `pending_input` borrows from it, or from the response's
    /// received bytes at startup, so a read needs no intermediate copy.
    /// Identity bodies on the direct route skip it and read into right-sized
    /// owned allocations.
    read_buffer: []u8,
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
    /// Hand-back ticket for the pool; present only when the response head
    /// allows reuse. Redeemed after a clean framed completion, dropped on
    /// every failure path.
    pooled_return: ?http1_client.ConnectionReturn = null,
    wire_returned: bool = false,
    clean_for_pool: bool = true,

    const BodyState = union(enum) {
        content_length: usize,
        close_delimited,
        chunked: ChunkedState,
        finished,
    };

    const ChunkedState = struct {
        decoder: protocol.ChunkedDecoder = .{},
        decoded_body: std.array_list.Aligned(u8, null) = .empty,
        /// Bytes of `decoded_body` already appended to the queue; the live
        /// remainder is `decoded_body.items[consumed..]`. Compacting after
        /// every partial append would cost O(n²) over a backpressured burst,
        /// so compaction waits for the next decode (`compactForRefill`).
        /// That keeps `decoded_body.items.len` equal to the remainder
        /// whenever the decoder checks its output limit.
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

    pub const Step = union(enum) {
        /// The body ended and the queue completed.
        done,
        /// The queue is at its watermark; the resume credit of a queued
        /// chunk wakes the continuation.
        paused,
        /// The wire must receive (or, under TLS, send) before the body can
        /// go on.
        wait: IoInterest,
    };

    const PauseError = error{Http1BodyPaused};

    /// Takes `wire` and `response` on success; on error the caller keeps
    /// both. Retains `queue` for the continuation's life.
    pub fn init(
        allocator: std.mem.Allocator,
        pool: *http1_client.Http1Pool,
        wire: *Wire,
        response: OwnedResponseHead,
        source_id: u64,
        head_request: bool,
        encoding: decompress.Encoding,
        pump_limits: stream_pump.Limits,
        queue: *ResponseQueue,
        ready_ctx: ?*anyopaque,
        ready_fn: Http1BodyReadyFn,
        ready_event: BodyReadyEvent,
        pooled_return: ?http1_client.ConnectionReturn,
    ) !*Continuation {
        var pump = try stream_pump.Pump.init(encoding, pump_limits);
        errdefer pump.deinit();
        const read_buffer = try pool.acquireBodyReadBuffer();
        errdefer pool.releaseBodyReadBuffer(read_buffer);
        const state: BodyState = if (head_request or response.head.body_framing == .none)
            .finished
        else switch (response.head.body_framing) {
            .none => .finished,
            .content_length => blk: {
                if (encoding == .identity and response.head.content_length > pump.limits.max_decoded_bytes)
                    return error.FetchResponseTooLarge;
                break :blk .{ .content_length = response.head.content_length - response.head.initial_body_bytes.len };
            },
            .close_delimited => .close_delimited,
            .http1_chunked => .{ .chunked = .{} },
        };
        // Bytes the head's receive carried past this response's framing
        // answer no request. The response still completes and its wire is
        // dropped instead of pooled, as when such bytes arrive in a later
        // receive and stay unread in the wire, so the outcome never depends
        // on how the peer's bytes were segmented.
        const surplus_after_framing = switch (state) {
            .finished => response.head.post_head_bytes.len != 0,
            .content_length => response.head.post_head_bytes.len > response.head.content_length,
            .close_delimited, .chunked => false,
        };
        const continuation = try allocator.create(Continuation);
        queue.retain();
        continuation.* = .{
            .allocator = allocator,
            .pool = pool,
            .wire = wire,
            .response = response,
            .source_id = source_id,
            .encoding = encoding,
            .pump = pump,
            .queue = queue,
            .ready_ctx = ready_ctx,
            .ready_fn = ready_fn,
            .ready_event = ready_event,
            .read_buffer = read_buffer,
            // A HEAD or bodiless response has no body, so bytes read after
            // its head are dropped; a framed body keeps them as its first
            // bytes.
            .pending_input = if (state == .finished) &.{} else response.head.initial_body_bytes,
            .state = state,
            .pooled_return = pooled_return,
            .clean_for_pool = !surplus_after_framing,
        };
        return continuation;
    }

    pub fn step(self: *Continuation) !Step {
        return self.runUntilBlocked() catch |err| switch (err) {
            error.Http1BodyPaused => return .paused,
            else => return err,
        };
    }

    /// Ends a continuation whose `step` returned `.done`: wakes the fetch's
    /// reader, returns the wire to the pool when the body ended cleanly or
    /// releases it otherwise, and frees the continuation.
    pub fn finish(self: *Continuation) void {
        std.debug.assert(self.state == .finished);
        self.ready_fn(self.ready_ctx, self.ready_event);
        self.returnWireIfReusable();
        self.deinit();
    }

    /// Ends a continuation on an error or a cancel: fails the queue with
    /// `message_text`, wakes the fetch's reader, releases the wire and frees
    /// the continuation.
    pub fn failAndDeinit(self: *Continuation, message_text: []const u8) void {
        _ = self.queue.fail(self.allocator, message_text);
        self.ready_fn(self.ready_ctx, self.ready_event);
        self.deinit();
    }

    /// Returns the wire to the pool after a clean completion: the body ended
    /// by its own framing (close-delimited bodies carry no ticket) without
    /// bare-LF leniency in its chunk lines, and no byte was read past it.
    /// Otherwise `deinit` releases the wire.
    fn returnWireIfReusable(self: *Continuation) void {
        const ticket = self.pooled_return orelse return;
        self.pooled_return = null;
        if (!self.clean_for_pool or self.pendingSlice().len != 0)
            return;
        const now_ns = config_mod.monotonicNowNs() catch return;
        self.wire_returned = true;
        ticket.give(self.wire, now_ns);
    }

    fn deinit(self: *Continuation) void {
        const allocator = self.allocator;
        self.queue.release(allocator);
        switch (self.state) {
            .chunked => |*chunked| chunked.deinit(allocator),
            else => {},
        }
        self.pump.deinit();
        self.response.deinit();
        if (!self.wire_returned)
            self.pool.releaseWire(self.wire);
        self.pool.releaseBodyReadBuffer(self.read_buffer);
        allocator.destroy(self);
    }

    fn runUntilBlocked(self: *Continuation) !Step {
        while (true) {
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
                        switch (try self.stepIdentityDirect(remaining_wire)) {
                            .read => |read_len| {
                                self.state.content_length = remaining_wire - read_len;
                                continue;
                            },
                            .eof => return error.FetchResponseTruncated,
                            .wait => |interest| return .{ .wait = interest },
                            // A spent decoded budget or the drip route
                            // falls through to the buffered read, whose pump
                            // append tells a body ending exactly at the
                            // budget from one that exceeds it.
                            .buffered => {},
                        }
                    }
                    const read_len = switch (try self.wire.readStep(self.read_buffer[0..@min(self.read_buffer.len, remaining_wire)])) {
                        .ready => |read_len| read_len,
                        .eof => return error.FetchResponseTruncated,
                        .wait => |interest| return .{ .wait = interest },
                    };
                    // A buffered read this large means bulk arrivals, so the
                    // next read takes the direct route again.
                    if (read_len >= initial_direct_read_bytes)
                        self.direct_read_enabled = true;
                    self.state.content_length = remaining_wire - read_len;
                    self.setPendingInput(self.read_buffer[0..read_len]);
                },
                .close_delimited => {
                    if (self.encoding == .identity) {
                        switch (try self.stepIdentityDirect(self.read_buffer.len)) {
                            .read => continue,
                            .eof => {
                                self.state = .finished;
                                continue;
                            },
                            .wait => |interest| return .{ .wait = interest },
                            .buffered => {},
                        }
                    }
                    const read_len = switch (try self.wire.readStep(self.read_buffer)) {
                        .ready => |read_len| read_len,
                        .eof => {
                            self.state = .finished;
                            continue;
                        },
                        .wait => |interest| return .{ .wait = interest },
                    };
                    // As in the content-length arm, a large buffered read
                    // returns to the direct route.
                    if (read_len >= initial_direct_read_bytes)
                        self.direct_read_enabled = true;
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
                    const read_len = switch (try self.wire.readStep(self.read_buffer)) {
                        .ready => |read_len| read_len,
                        .eof => return error.FetchResponseTruncated,
                        .wait => |interest| return .{ .wait = interest },
                    };
                    self.setPendingInput(self.read_buffer[0..read_len]);
                },
            }
        }
    }

    const DirectRead = union(enum) {
        /// `read_len` bytes went to the queue.
        read: usize,
        eof,
        wait: IoInterest,
        /// Take the buffered route for this read.
        buffered,
    };

    /// Direct route for identity bodies: read into a fresh allocation of the
    /// right size and hand it to the queue, which takes ownership instead of
    /// copying it. Capacity is probed before the read with the same check
    /// the pump's append makes, so a full queue pauses before reading instead
    /// of holding bytes it cannot append. The pause stays live because the
    /// append that exhausted capacity carried the resume credit
    /// (`stream_pump.zig:Pump.resumeCreditFor`).
    fn stepIdentityDirect(self: *Continuation, wire_cap: usize) !DirectRead {
        std.debug.assert(self.pendingSlice().len == 0);
        // Drip origins take the buffered route (see `direct_read_enabled`).
        if (!self.direct_read_enabled)
            return .buffered;
        const available = switch (self.pump.identityCapacity(self.queue)) {
            .budget_exhausted => return .buffered,
            .paused => return error.Http1BodyPaused,
            .available => |n| n,
        };
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
        var owned_kept = false;
        defer if (!owned_kept) self.allocator.free(owned);
        const read_len = switch (try self.wire.readStep(owned)) {
            .ready => |read_len| read_len,
            .eof => return .eof,
            .wait => |interest| return .{ .wait = interest },
        };
        self.direct_read_hint = if (read_len == target)
            @min(self.direct_read_hint *| 2, self.read_buffer.len)
        else
            @max(read_len, initial_direct_read_bytes);
        // A read far below the floor marks a drip origin; switch to the
        // buffered route before the allocate-and-shrink cost repeats.
        if (read_len < initial_direct_read_bytes / 2 and read_len < target)
            self.direct_read_enabled = false;
        if (read_len < owned.len) {
            // The allocator usually shrinks in place. A copy across size
            // classes is rare and costs no more than the buffered route's
            // copy of every read.
            owned = try self.allocator.realloc(owned, read_len);
        }
        const result = try self.pump.appendHttp1IdentityOwned(
            self.allocator,
            self.queue,
            owned,
            body_credit.h1Resume(self.source_id),
        );
        owned_kept = true;
        std.debug.assert(result.consumed == read_len);
        if (result.ready)
            self.ready_fn(self.ready_ctx, self.ready_event);
        return .{ .read = read_len };
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
                // Bytes past the last chunk answer no request, as in `init`:
                // they cost the wire's reuse, not the body.
                if (decoded.done and self.pendingSlice().len != 0) {
                    self.clean_for_pool = false;
                    self.advancePending(self.pendingSlice().len);
                }
                return decoded.consumed != 0 or chunked.remainder().len != 0 or decoded.done;
            },
            else => {
                const result = try self.pump.appendHttp1DataAvailable(
                    self.allocator,
                    self.queue,
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
            self.queue,
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
            self.queue,
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
