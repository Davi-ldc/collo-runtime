//! One HTTP/1 request hop as a resumable state machine on the owner thread:
//! lease a pooled wire or ask for a dial, write the request, read and route
//! the response head, then either drain a redirect body or hand the body to
//! a continuation.
//!
//! `drive` never blocks. It returns a `Need` naming what the owner must wait
//! for (the wire's readiness, a dialed wire, publication of the head) and
//! resumes from the stored state on the next call. A redirect ends the hop
//! with `.redirect`; the engine restarts the request for the next hop with a
//! new plan. The hop's plan, which the engine prepared once, is borrowed
//! until the hop ends.

const std = @import("std");
const core = @import("collo_egress_core");
const limits = @import("collo_limits");

const config_mod = @import("../config.zig");
const headers_mod = @import("../request/headers.zig");
const http1_body = @import("body.zig");
const http1_client = @import("root.zig");
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const redirect_mod = @import("../request/redirect.zig");
const request_plan_mod = @import("../request/plan.zig");
const wire_mod = @import("../wire.zig");

const Config = config_mod.Config;
const Continuation = http1_body.Continuation;
const FetchOptions = redirect_mod.FetchOptions;
const Http1Pool = http1_client.Http1Pool;
const IoInterest = config_mod.IoInterest;
const OwnedResponseHead = message.OwnedResponseHead;
const RedirectTarget = redirect_mod.RedirectTarget;
const RequestPlan = request_plan_mod.RequestPlan;
const ResponseQueue = core.ResponseQueue;
const StreamedResponseHead = message.StreamedResponseHead;
const Wire = wire_mod.Wire;

const cloneStreamedResponseHead = message.cloneStreamedResponseHead;
const keepAliveTimeoutNs = message.keepAliveTimeoutNs;
const redirectTarget = redirect_mod.redirectTarget;

/// Bytes one read takes from the wire while the exchange reads a head or
/// drains a redirect body.
const read_chunk_bytes: usize = 8192;

/// What the exchange needs from its caller before it can make progress.
pub const Need = union(enum) {
    /// Wait until the wire can make progress; expiry semantics per
    /// `Io.on_expire`.
    io: Io,
    /// Pool miss, or replay after a pooled wire died: the engine dials the
    /// plan's origin and hands the wire back through `adoptConnection`.
    connect,
    /// Response head parsed. The caller publishes it, then calls
    /// `markPublished()` and drives again. The pointed-at head stays owned
    /// by the exchange.
    publish_head: *const StreamedResponseHead,
    /// The hop ended in a redirect. The caller takes ownership of the
    /// target's url, method and headers, allocated with the exchange's
    /// allocator; its body is not owned (the current request's body, or
    /// empty after a rewrite to GET).
    redirect: RedirectTarget,
    /// Framed response body continues on the returned continuation. The
    /// exchange is finished; only `deinit` remains.
    body: *Continuation,
    /// Nothing left for the exchange: the head was published and the body
    /// already failed inline (unsupported encoding). The caller wakes the
    /// task.
    done,
};

pub const Io = struct {
    interest: IoInterest,
    /// Error reported when the wait's stall deadline fires before the total
    /// request deadline: FetchReadTimeout or FetchWriteTimeout.
    timeout_err: anyerror = error.FetchReadTimeout,
    on_expire: OnExpire = .fail_fetch,

    pub const OnExpire = enum {
        /// Stall expiry fails the fetch (head exchange, body).
        fail_fetch,
        /// Stall expiry only gives up connection reuse: draining a redirect
        /// body just keeps the wire poolable, so its failure must not fail
        /// the fetch. The caller calls `abandonRedirectDrain()` and drives
        /// again.
        abandon_reuse,
    };
};

pub const Exchange = struct {
    allocator: std.mem.Allocator,
    pool: *Http1Pool,
    /// Borrowed until the hop ends; it names the hop's target, method and
    /// headers, which hold until the engine prepares the next hop.
    plan: *const RequestPlan,
    config: Config,
    options: FetchOptions,
    request_body: []const u8,
    redirect_count: usize,
    /// The body-credit routing id the continuation's resume credits carry,
    /// which the engine matches to this fetch's pending.
    resume_source_id: u64,
    queue: *ResponseQueue,
    ready_ctx: ?*anyopaque,
    ready_fn: http1_body.Http1BodyReadyFn,
    ready_event: http1_body.BodyReadyEvent,

    lease: ?Http1Pool.LeasedConnection = null,
    response: ?OwnedResponseHead = null,
    published_head: ?StreamedResponseHead = null,
    head_progress: message.HeadProgress = .{},
    retry_used: bool = false,
    state: State = .lease,

    const State = union(enum) {
        lease,
        awaiting_connect,
        prep_write,
        write_head: WriteState,
        read_head: ReadHead,
        route_head,
        drain_redirect: Drain,
        publish_pending,
        after_publish,
        finished,
    };

    const WriteState = struct {
        /// Owned serialized request head, followed by the body when a small
        /// body was coalesced into the same write.
        owned: []u8,
        /// Segments to write in order; segment 0 is always `owned`, segment 1
        /// (when present) borrows the request body.
        segments: [2][]const u8,
        segment_count: usize,
        index: usize = 0,
        offset: usize = 0,

        fn deinit(self: *WriteState, allocator: std.mem.Allocator) void {
            allocator.free(self.owned);
            self.* = undefined;
        }
    };

    const ReadHead = struct {
        received: std.array_list.Aligned(u8, null) = .empty,
        scan_start: usize = 0,
        interim_count: usize = 0,

        fn deinit(self: *ReadHead, allocator: std.mem.Allocator) void {
            self.received.deinit(allocator);
            self.* = undefined;
        }
    };

    /// A redirect body, read and dropped only so the wire stays poolable.
    /// `config.max_redirect_drain_bytes` caps what it reads; past that the
    /// drain gives up the wire instead of failing the fetch.
    const Drain = struct {
        redirect: ?RedirectTarget,
        framing: union(enum) {
            content_length: usize,
            close_delimited,
            chunked: protocol.ChunkedDecoder,
            done,
        } = .done,
        drained_bytes: usize = 0,
        clean_for_pool: bool = true,
        abandoned: bool = false,

        fn abandon(self: *Drain) void {
            self.abandoned = true;
            self.clean_for_pool = false;
            self.framing = .done;
        }

        fn deinit(self: *Drain, allocator: std.mem.Allocator) void {
            if (self.redirect) |redirect| {
                allocator.free(redirect.url);
                allocator.free(redirect.method);
                headers_mod.freeHeaders(allocator, redirect.headers);
            }
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        pool: *Http1Pool,
        plan: *const RequestPlan,
        request_body: []const u8,
        config: Config,
        options: FetchOptions,
        redirect_count: usize,
        resume_source_id: u64,
        queue: *ResponseQueue,
        ready_ctx: ?*anyopaque,
        ready_fn: http1_body.Http1BodyReadyFn,
        ready_event: http1_body.BodyReadyEvent,
    ) !*Exchange {
        const exchange = try allocator.create(Exchange);
        exchange.* = .{
            .allocator = allocator,
            .pool = pool,
            .plan = plan,
            .config = config,
            .options = options,
            .request_body = request_body,
            .redirect_count = redirect_count,
            .resume_source_id = resume_source_id,
            .queue = queue,
            .ready_ctx = ready_ctx,
            .ready_fn = ready_fn,
            .ready_event = ready_event,
        };
        return exchange;
    }

    /// Frees the exchange and releases the wire it still holds.
    pub fn deinit(self: *Exchange) void {
        const allocator = self.allocator;
        switch (self.state) {
            .write_head => |*write_state| write_state.deinit(allocator),
            .read_head => |*read_head| read_head.deinit(allocator),
            .drain_redirect => |*drain| drain.deinit(allocator),
            else => {},
        }
        if (self.published_head) |*head|
            head.deinit(allocator);
        if (self.response) |*response|
            response.deinit();
        if (self.lease) |lease|
            self.pool.releaseWire(lease.wire);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn connectionWire(self: *const Exchange) ?*Wire {
        const lease = self.lease orelse return null;
        return lease.wire;
    }

    /// Takes a dialed wire (pool miss or replay) after `drive` returned
    /// `.connect`.
    pub fn adoptConnection(self: *Exchange, wire: *Wire) void {
        std.debug.assert(self.state == .awaiting_connect);
        std.debug.assert(self.lease == null);
        self.lease = .{
            .wire = wire,
            .created_mono_ns = monotonicNowNs(),
        };
        self.state = .prep_write;
    }

    /// The caller published the head emitted by `.publish_head`.
    pub fn markPublished(self: *Exchange) void {
        std.debug.assert(self.state == .publish_pending);
        self.state = .after_publish;
    }

    /// The redirect-drain wait expired: give up on wire reuse and let the
    /// next `drive` emit the redirect.
    pub fn abandonRedirectDrain(self: *Exchange) void {
        switch (self.state) {
            .drain_redirect => |*drain| drain.abandon(),
            else => {},
        }
    }

    /// The data driver failed a receive or send on the leased wire with
    /// `err`. While the head is written or read this is the wire dying under
    /// the request, which may replay it on a fresh dial (`retryHeadOrFail`);
    /// during a redirect drain it costs only the wire's reuse, and the next
    /// `drive` emits the redirect. Anything else fails the hop with `err`.
    pub fn failWire(self: *Exchange, err: anyerror) anyerror!Need {
        switch (self.state) {
            .write_head, .read_head => return self.retryHeadOrFail(err),
            .drain_redirect => |*drain| {
                drain.abandon();
                return self.drive();
            },
            else => return err,
        }
    }

    pub fn drive(self: *Exchange) anyerror!Need {
        while (true) {
            switch (self.state) {
                .lease => {
                    if (self.pool.take(&self.plan.origin_key, monotonicNowNs())) |leased| {
                        self.lease = leased;
                        self.state = .prep_write;
                        continue;
                    }
                    self.state = .awaiting_connect;
                    return .connect;
                },
                .awaiting_connect => return .connect,
                .prep_write => {
                    try self.prepareWrite();
                    continue;
                },
                .write_head => {
                    if (try self.driveHeadWrite()) |need|
                        return need;
                    continue;
                },
                .read_head => {
                    if (self.driveHeadRead()) |maybe_need| {
                        if (maybe_need) |need|
                            return need;
                        continue;
                    } else |err| return try self.retryHeadOrFail(err);
                },
                .route_head => {
                    if (try self.routeHead()) |need|
                        return need;
                    continue;
                },
                .drain_redirect => {
                    if (try self.driveDrain()) |need|
                        return need;
                    continue;
                },
                .publish_pending => return .{ .publish_head = &self.published_head.? },
                .after_publish => return try self.finishAfterPublish(),
                .finished => unreachable,
            }
        }
    }

    fn prepareWrite(self: *Exchange) !void {
        const plan = self.plan;
        const request_head = try protocol.serializeRequestHead(self.allocator, .{
            .method = plan.method,
            .target = plan.request_target,
            .host = plan.request_authority,
            .headers = plan.parsed_headers.headers.items,
            .content_length = if (self.request_body.len != 0 or message.methodHasRequestBodySemantics(plan.method))
                self.request_body.len
            else
                null,
            .close_after_response = false,
        });
        var head_owned = true;
        errdefer if (head_owned)
            self.allocator.free(request_head);

        var write_state: WriteState = undefined;
        if (self.request_body.len != 0 and self.request_body.len <= message.max_coalesced_body_bytes) {
            const combined = try self.allocator.alloc(u8, request_head.len + self.request_body.len);
            @memcpy(combined[0..request_head.len], request_head);
            @memcpy(combined[request_head.len..], self.request_body);
            self.allocator.free(request_head);
            head_owned = false;
            write_state = .{
                .owned = combined,
                .segments = .{ combined, &.{} },
                .segment_count = 1,
            };
        } else {
            head_owned = false;
            write_state = .{
                .owned = request_head,
                .segments = .{ request_head, self.request_body },
                .segment_count = if (self.request_body.len != 0) 2 else 1,
            };
        }
        self.state = .{ .write_head = write_state };
    }

    /// Hands the request to the wire, which queues it for the data driver to
    /// send; a full send queue waits for writability.
    fn driveHeadWrite(self: *Exchange) !?Need {
        const write_state = &self.state.write_head;
        const wire = self.lease.?.wire;
        while (write_state.index < write_state.segment_count) {
            const segment = write_state.segments[write_state.index];
            if (write_state.offset >= segment.len) {
                write_state.index += 1;
                write_state.offset = 0;
                continue;
            }
            const step = wire.writeStep(segment[write_state.offset..]) catch |err|
                return try self.retryHeadOrFail(err);
            switch (step) {
                .ready => |written| write_state.offset += written,
                .eof => return try self.retryHeadOrFail(error.FetchWriteFailed),
                .wait => |interest| return .{ .io = .{
                    .interest = interest,
                    .timeout_err = error.FetchWriteTimeout,
                } },
            }
        }
        wire.flushOutgoing() catch |err|
            return try self.retryHeadOrFail(err);
        var finished = self.state.write_head;
        finished.deinit(self.allocator);
        self.state = .{ .read_head = .{} };
        return null;
    }

    /// Returns `null` on state advance, a `Need` to wait, or an error the
    /// caller routes through the pooled-replay decision.
    fn driveHeadRead(self: *Exchange) !?Need {
        const read_head = &self.state.read_head;
        const wire = self.lease.?.wire;
        while (true) {
            if (try protocol.completeResponseHead(
                self.allocator,
                read_head.received.items,
                &read_head.scan_start,
                limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX,
            )) |parsed| {
                var head = parsed;
                if (head.status_code >= 100 and head.status_code < 200 and head.status_code != 101) {
                    const consumed_len = head.consumed_len;
                    head.deinit();
                    read_head.interim_count += 1;
                    if (read_head.interim_count > message.max_interim_responses)
                        return error.TooManyInterimResponses;
                    std.mem.copyForwards(
                        u8,
                        read_head.received.items[0 .. read_head.received.items.len - consumed_len],
                        read_head.received.items[consumed_len..],
                    );
                    read_head.received.items.len -= consumed_len;
                    read_head.scan_start = 0;
                    continue;
                }
                const received = read_head.received;
                self.response = .{ .allocator = self.allocator, .received = received, .head = head };
                self.state = .route_head;
                return null;
            }

            var chunk: [read_chunk_bytes]u8 = undefined;
            switch (try wire.readStep(&chunk)) {
                .ready => |read_len| {
                    if (read_len == 0)
                        return error.FetchResponseTruncated;
                    self.head_progress.response_bytes_received = true;
                    try read_head.received.appendSlice(self.allocator, chunk[0..read_len]);
                },
                .eof => return error.FetchResponseTruncated,
                .wait => |interest| return .{ .io = .{
                    .interest = interest,
                    .timeout_err = error.FetchReadTimeout,
                } },
            }
        }
    }

    /// Pooled-wire replay, at most once per exchange, as undici and Bun do
    /// it: when a reused wire dies before any response byte, an idempotent
    /// request without a body is retried on a fresh dial.
    fn retryHeadOrFail(self: *Exchange, err: anyerror) anyerror!Need {
        const lease = self.lease orelse return err;
        if (self.retry_used or
            !lease.from_pool or
            !http1_client.isReplayableBeforeResponse(self.plan.method, self.request_body) or
            !http1_client.isHttp1ConnectionDeathBeforeResponse(err, self.head_progress))
            return err;
        self.retry_used = true;
        self.head_progress = .{};
        switch (self.state) {
            .write_head => |*write_state| write_state.deinit(self.allocator),
            .read_head => |*read_head| read_head.deinit(self.allocator),
            else => {},
        }
        self.pool.releaseWire(lease.wire);
        self.lease = null;
        self.state = .awaiting_connect;
        return .connect;
    }

    fn routeHead(self: *Exchange) !?Need {
        const head = &self.response.?.head;
        if (head.status_code == 101)
            return error.UnsupportedFetchProtocolUpgrade;

        if (try redirectTarget(
            self.allocator,
            self.plan.url,
            self.plan.method,
            self.plan.parsed_headers.headers.items,
            head.status_code,
            head.headers,
            self.options,
            self.redirect_count,
        )) |redirect| {
            var drain = Drain{ .redirect = redirect };
            self.initDrainFraming(&drain);
            self.state = .{ .drain_redirect = drain };
            return null;
        }

        self.published_head = try cloneStreamedResponseHead(
            self.allocator,
            head.*,
            self.plan.url,
            self.redirect_count != 0,
        );
        self.state = .publish_pending;
        return .{ .publish_head = &self.published_head.? };
    }

    fn isHeadRequest(self: *const Exchange) bool {
        return std.mem.eql(u8, self.plan.method, "HEAD");
    }

    fn initDrainFraming(self: *Exchange, drain: *Drain) void {
        const head = &self.response.?.head;
        // No body: drained, and reusable unless bytes followed the head.
        if (self.isHeadRequest() or head.body_framing == .none) {
            if (head.post_head_bytes.len != 0)
                drain.abandon();
            return;
        }
        const cap = self.config.max_redirect_drain_bytes;
        switch (head.body_framing) {
            .none => unreachable,
            .content_length => {
                if (head.content_length > cap or head.post_head_bytes.len > head.content_length)
                    return drain.abandon();
                drain.drained_bytes = head.initial_body_bytes.len;
                drain.framing = .{ .content_length = head.content_length - head.initial_body_bytes.len };
                if (drain.framing.content_length == 0)
                    drain.framing = .done;
            },
            .close_delimited => {
                if (head.initial_body_bytes.len > cap)
                    return drain.abandon();
                drain.drained_bytes = head.initial_body_bytes.len;
                drain.framing = .close_delimited;
            },
            .http1_chunked => {
                var decoder = protocol.ChunkedDecoder{};
                const decoded = decoder.decode(
                    self.allocator,
                    head.initial_body_bytes,
                    null,
                    .{ .max_output_bytes = cap, .max_wire_bytes = cap },
                ) catch return drain.abandon();
                if (decoded.done) {
                    if (decoded.consumed != head.initial_body_bytes.len)
                        return drain.abandon();
                    drain.clean_for_pool = !decoder.saw_lenient_line_end;
                    drain.framing = .done;
                    return;
                }
                drain.framing = .{ .chunked = decoder };
            },
        }
    }

    fn driveDrain(self: *Exchange) !?Need {
        const drain = &self.state.drain_redirect;
        const wire = self.lease.?.wire;
        const cap = self.config.max_redirect_drain_bytes;
        while (drain.framing != .done) {
            var chunk: [read_chunk_bytes]u8 = undefined;
            const read_cap: usize = switch (drain.framing) {
                .content_length => |remaining| @min(chunk.len, remaining),
                else => chunk.len,
            };
            const step = wire.readStep(chunk[0..read_cap]) catch {
                drain.abandon();
                break;
            };
            const read_len = switch (step) {
                .ready => |read_len| read_len,
                .eof => 0,
                .wait => |interest| return .{ .io = .{
                    .interest = interest,
                    .timeout_err = error.FetchReadTimeout,
                    .on_expire = .abandon_reuse,
                } },
            };
            if (read_len == 0) {
                switch (drain.framing) {
                    .close_delimited => drain.framing = .done,
                    else => drain.abandon(),
                }
                break;
            }
            switch (drain.framing) {
                .done => unreachable,
                .content_length => |remaining| {
                    if (remaining == read_len)
                        drain.framing = .done
                    else
                        drain.framing = .{ .content_length = remaining - read_len };
                },
                .close_delimited => {
                    drain.drained_bytes += read_len;
                    if (drain.drained_bytes > cap) {
                        drain.abandon();
                        break;
                    }
                },
                .chunked => |*decoder| {
                    const decoded = decoder.decode(
                        self.allocator,
                        chunk[0..read_len],
                        null,
                        .{ .max_output_bytes = cap, .max_wire_bytes = cap },
                    ) catch {
                        drain.abandon();
                        break;
                    };
                    if (decoded.done) {
                        if (decoded.consumed != read_len) {
                            drain.abandon();
                            break;
                        }
                        drain.clean_for_pool = !decoder.saw_lenient_line_end;
                        drain.framing = .done;
                    }
                },
            }
        }

        // Hop end: settle the wire, then hand the redirect out.
        if (!drain.abandoned and drain.clean_for_pool and
            message.responseReusableForPool(self.response.?.head))
        {
            const lease = self.lease.?;
            self.lease = null;
            self.pool.put(
                self.plan.origin_key,
                self.config,
                lease,
                monotonicNowNs(),
                keepAliveTimeoutNs(self.response.?.head.headers),
            );
        }
        const redirect = drain.redirect.?;
        drain.redirect = null;
        var finished = self.state.drain_redirect;
        finished.deinit(self.allocator);
        self.state = .finished;
        return .{ .redirect = redirect };
    }

    fn finishAfterPublish(self: *Exchange) !Need {
        const lease = self.lease.?;
        const head = &self.response.?.head;
        const response_encoding = http1_client.responseEncodingForHead(head.*) catch |err| {
            _ = self.queue.fail(self.allocator, @errorName(err));
            self.state = .finished;
            return .done;
        };

        const ticket: ?http1_client.ConnectionReturn = if (message.responseReusableForPool(head.*)) .{
            .pool = self.pool,
            .key = self.plan.origin_key,
            .config = self.config,
            .created_mono_ns = lease.created_mono_ns,
            .requests_served = lease.requests_served,
            .keep_alive_hint_ns = keepAliveTimeoutNs(head.headers),
        } else null;

        const continuation = try Continuation.init(
            self.allocator,
            self.pool,
            lease.wire,
            self.response.?,
            self.resume_source_id,
            self.isHeadRequest(),
            response_encoding,
            self.config.streamPumpLimits(),
            self.queue,
            self.ready_ctx,
            self.ready_fn,
            self.ready_event,
            ticket,
        );
        // The wire and the response moved into the continuation.
        self.lease = null;
        self.response = null;
        self.state = .finished;
        return .{ .body = continuation };
    }
};

/// The egress clock (`config.zig:monotonicNowNs`), or the largest instant
/// when it cannot be read, which expires every pooled entry instead of
/// trusting a deadline nobody can check.
fn monotonicNowNs() u64 {
    return config_mod.monotonicNowNs() catch std.math.maxInt(u64);
}
