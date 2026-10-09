//! One HTTP/1 request hop as a resumable state machine on the owner thread:
//! lease or dial a connection, write the request, read and route the response
//! head, then either drain a redirect body or hand the body to a continuation.
//!
//! `drive` never blocks. It returns a `Need` naming what the owner must wait
//! for (socket readiness, a dial on a connector thread, publication of the
//! head) and resumes from the stored state on the next call. A redirect ends
//! the hop with `.redirect`; the engine adds the hop's meters to the task's
//! cross-hop base and restarts the request for the next hop
//! (`followH1Redirect` in engine/h2_engine.zig).
//!
//! `wire_bytes` and `cost_bytes` count this attempt only, and every absolute
//! report (body-pipe meters, the continuation's counters) adds the base
//! captured at init. Replaying a request after its pooled connection died
//! drops the attempt's billed bytes and keeps its ciphertext as cost.

const std = @import("std");
const accounting = @import("collo_egress_accounting");
const core = @import("collo_egress_core");
const limits = @import("collo_limits");

const cancel_probe_mod = @import("../cancel_probe.zig");
const config_mod = @import("../config.zig");
const connection_mod = @import("../connection.zig");
const headers_mod = @import("../request/headers.zig");
const http1 = @import("protocol/root.zig");
const http1_body = @import("body.zig");
const http1_client = @import("root.zig");
const http1_wire = @import("wire.zig");
const readiness = @import("collo_egress_readiness");
const redirect_mod = @import("../request/redirect.zig");
const request_plan_mod = @import("../request/plan.zig");

const fetch_body = core.fetch_body;

const CancelProbe = cancel_probe_mod.CancelProbe;
const Config = config_mod.Config;
const Continuation = http1_body.Continuation;
const FetchOptions = redirect_mod.FetchOptions;
const HttpConnection = connection_mod.HttpConnection;
const Http1Pool = http1_client.Http1Pool;
const IoInterest = config_mod.IoInterest;
const OwnedResponseHead = http1_wire.OwnedResponseHead;
const RedirectTarget = redirect_mod.RedirectTarget;
const RequestPlan = request_plan_mod.RequestPlan;
const StreamedResponseHead = http1_wire.StreamedResponseHead;

const appendResponseChunk = request_plan_mod.appendResponseChunk;
const cloneStreamedResponseHead = http1_wire.cloneStreamedResponseHead;
const keepAliveTimeoutNs = http1_wire.keepAliveTimeoutNs;
const prepareRequest = request_plan_mod.prepareRequest;
const redirectTarget = redirect_mod.redirectTarget;

/// What the exchange needs from its caller before it can make progress.
pub const Need = union(enum) {
    /// Park on socket readiness; expiry semantics per `Io.on_expire`.
    io: Io,
    /// Pool miss, or replay after a pooled connection died: a connector
    /// thread must dial `task.url` with this exchange's config and hand the
    /// connection back through `adoptConnection`.
    connect,
    /// Response head parsed. The caller publishes it, then calls
    /// `markPublished()` and drives again. The pointed-at head stays owned
    /// by the exchange.
    publish_head: *const StreamedResponseHead,
    /// The hop ended in a redirect. The caller takes ownership of the
    /// target's url, method and headers, allocated with the exchange's
    /// allocator; its body is not owned (the current request's body, or
    /// empty after a rewrite to GET). The caller adds `hopBilled()` and
    /// `hopCost()` to the task's base before starting the next hop.
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
    /// Error reported when the park's stall deadline fires before the total
    /// request deadline: FetchReadTimeout or FetchWriteTimeout.
    timeout_err: anyerror = error.FetchReadTimeout,
    on_expire: OnExpire = .fail_fetch,

    pub const OnExpire = enum {
        /// Stall expiry fails the fetch (head exchange, body).
        fail_fetch,
        /// Stall expiry only gives up connection reuse: draining a redirect
        /// body just keeps the connection poolable, so its failure must not
        /// fail the fetch. The caller calls `abandonRedirectDrain()` and
        /// drives again.
        abandon_reuse,
    };
};

pub const Exchange = struct {
    allocator: std.mem.Allocator,
    pool: *Http1Pool,
    config: Config,
    options: FetchOptions,
    /// Borrowed request fields: the engine's pending holds a task reference,
    /// and the task's url/method/headers/body are stable for the duration of
    /// one hop (`replaceRequest` only runs between hops).
    url: []const u8,
    method: []const u8,
    headers: []const http1.Header,
    request_body: []const u8,
    redirect_count: usize,
    /// Cross-hop base captured at init; added to the attempt-local meters at
    /// every absolute reporting point.
    base: BaseMeters,
    /// Attempt-local plaintext (billed) meter.
    wire_bytes: accounting.Bytes = .{},
    /// Attempt-local ciphertext cost (BIO take-deltas).
    cost_bytes: u64 = 0,
    resume_source_id: u64,
    body_pipe: *fetch_body.Body,
    ready_ctx: ?*anyopaque,
    ready_fn: http1_body.Http1BodyReadyFn,
    ready_event: http1_body.BodyReadyEvent,

    plan: ?RequestPlan = null,
    lease: ?Http1Pool.LeasedConnection = null,
    response: ?OwnedResponseHead = null,
    published_head: ?StreamedResponseHead = null,
    head_progress: http1_wire.HeadProgress = .{},
    retry_used: bool = false,
    state: State = .lease,

    pub const BaseMeters = struct {
        billed_sent: u64 = 0,
        billed_received: u64 = 0,
        cost: u64 = 0,
    };

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

        /// Head and body bytes handed to the connection so far: every fully
        /// written segment plus the offset into the current one. An exchange
        /// that fails mid-write bills this, as HTTP/2 bills each DATA write
        /// and never the queued remainder.
        fn writtenPrefix(self: *const WriteState) u64 {
            var written: u64 = 0;
            for (self.segments[0..self.segment_count], 0..) |segment, segment_index| {
                if (segment_index < self.index) {
                    written +|= segment.len;
                } else if (segment_index == self.index) {
                    written +|= @min(self.offset, segment.len);
                    break;
                }
            }
            return written;
        }

        fn deinit(self: *WriteState, allocator: std.mem.Allocator) void {
            allocator.free(self.owned);
            self.* = undefined;
        }
    };

    const ReadHead = struct {
        wire: std.array_list.Aligned(u8, null) = .empty,
        scan_start: usize = 0,
        interim_count: usize = 0,

        fn deinit(self: *ReadHead, allocator: std.mem.Allocator) void {
            self.wire.deinit(allocator);
            self.* = undefined;
        }
    };

    const Drain = struct {
        redirect: ?RedirectTarget,
        body: std.array_list.Aligned(u8, null) = .empty,
        framing: union(enum) {
            content_length: usize,
            close_delimited,
            chunked: http1.ChunkedDecoder,
            done,
        } = .done,
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
            self.body.deinit(allocator);
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        pool: *Http1Pool,
        url: []const u8,
        method: []const u8,
        request_body: []const u8,
        headers: []const http1.Header,
        config: Config,
        options: FetchOptions,
        redirect_count: usize,
        base: BaseMeters,
        resume_source_id: u64,
        body_pipe: *fetch_body.Body,
        ready_ctx: ?*anyopaque,
        ready_fn: http1_body.Http1BodyReadyFn,
        ready_event: http1_body.BodyReadyEvent,
    ) !*Exchange {
        const exchange = try allocator.create(Exchange);
        exchange.* = .{
            .allocator = allocator,
            .pool = pool,
            .config = config,
            .options = options,
            .url = url,
            .method = method,
            .headers = headers,
            .request_body = request_body,
            .redirect_count = redirect_count,
            .base = base,
            .resume_source_id = resume_source_id,
            .body_pipe = body_pipe,
            .ready_ctx = ready_ctx,
            .ready_fn = ready_fn,
            .ready_event = ready_event,
        };
        return exchange;
    }

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
        if (self.lease) |*lease|
            lease.deinit();
        if (self.plan) |*plan|
            plan.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn connectionFd(self: *const Exchange) ?std.posix.fd_t {
        const lease = &(self.lease orelse return null);
        return lease.connection.fd();
    }

    /// Adopt a connector-dialed connection (pool miss or replay). The
    /// exchange takes ownership.
    pub fn adoptConnection(self: *Exchange, connection: HttpConnection) void {
        std.debug.assert(self.state == .awaiting_connect);
        std.debug.assert(self.lease == null);
        self.lease = .{
            .connection = connection,
            .created_mono_ns = monotonicNowNs(),
        };
        self.state = .prep_write;
    }

    /// The caller published the head emitted by `.publish_head`.
    pub fn markPublished(self: *Exchange) void {
        std.debug.assert(self.state == .publish_pending);
        self.state = .after_publish;
    }

    /// The redirect-drain park expired: give up on connection reuse and let
    /// the next `drive` emit the redirect.
    pub fn abandonRedirectDrain(self: *Exchange) void {
        switch (self.state) {
            .drain_redirect => |*drain| drain.abandon(),
            else => {},
        }
    }

    /// This hop's billed plaintext (attempt-local; redirect folding adds it
    /// to the task's cross-hop base).
    pub fn hopBilled(self: *const Exchange) accounting.Bytes {
        return self.wire_bytes;
    }

    pub fn hopCost(self: *const Exchange) u64 {
        return self.cost_bytes;
    }

    pub fn drive(self: *Exchange, probe: CancelProbe) anyerror!Need {
        if (probe.isCanceled())
            return error.FetchAborted;
        while (true) {
            switch (self.state) {
                .lease => {
                    var plan = try prepareRequest(self.allocator, self.url, self.method, self.headers, self.config);
                    var plan_owned = true;
                    errdefer if (plan_owned)
                        plan.deinit();
                    const now_ns = monotonicNowNs();
                    self.pool.evictExpired(self.config, now_ns);
                    const lease = self.pool.take(&plan, self.config, now_ns);
                    self.plan = plan;
                    plan_owned = false;
                    if (lease) |leased| {
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
        const plan = &self.plan.?;
        const request_head = try http1.serializeRequestHead(self.allocator, .{
            .method = plan.method,
            .target = plan.request_target,
            .host = plan.request_authority,
            .headers = plan.parsed_headers.headers.items,
            .content_length = if (self.request_body.len != 0 or http1_wire.methodHasRequestBodySemantics(plan.method))
                self.request_body.len
            else
                null,
            .close_after_response = false,
        });
        var head_owned = true;
        errdefer if (head_owned)
            self.allocator.free(request_head);

        // Billed when the write is prepared. A replay drops the failed
        // attempt's counter, and a failed write is cut back to its written
        // prefix by settleFailureMeters.
        self.wire_bytes.addSent(request_head.len);
        self.wire_bytes.addSent(self.request_body.len);

        var write_state: WriteState = undefined;
        if (self.request_body.len != 0 and self.request_body.len <= http1_wire.max_coalesced_body_bytes) {
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

    fn driveHeadWrite(self: *Exchange) !?Need {
        const write_state = &self.state.write_head;
        const connection = &self.lease.?.connection;
        while (write_state.index < write_state.segment_count) {
            const segment = write_state.segments[write_state.index];
            if (write_state.offset >= segment.len) {
                write_state.index += 1;
                write_state.offset = 0;
                continue;
            }
            const step = connection.writeStep(segment[write_state.offset..]) catch |err|
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
        connection.flush() catch |err|
            return try self.retryHeadOrFail(err);
        var finished = self.state.write_head;
        finished.deinit(self.allocator);
        self.state = .{ .read_head = .{} };
        return null;
    }

    /// Returns `null` on state advance, a `Need` to park, or an error the
    /// caller routes through the pooled-replay decision.
    fn driveHeadRead(self: *Exchange) !?Need {
        const read_head = &self.state.read_head;
        const connection = &self.lease.?.connection;
        while (true) {
            if (try http1.completeResponseHead(
                self.allocator,
                read_head.wire.items,
                &read_head.scan_start,
                limits.headers.EGRESS_RESPONSE_HEADER_BYTES_MAX,
            )) |parsed| {
                var head = parsed;
                if (head.status_code >= 100 and head.status_code < 200 and head.status_code != 101) {
                    const consumed_len = head.consumed_len;
                    head.deinit();
                    read_head.interim_count += 1;
                    // Billed bytes exclude interim (1xx) heads, per the meter
                    // contract in core/fetch_body.zig; the HTTP/2 codec skips
                    // interim HEADERS the same way. The read loop billed
                    // these bytes on arrival, so they are refunded now that
                    // the head is known to be interim, and stay only in the
                    // ciphertext cost. The refund comes before the interim
                    // cap so the head that trips the cap is not billed when
                    // settleFailureMeters folds this failure.
                    self.wire_bytes.received -|= consumed_len;
                    if (read_head.interim_count > http1_wire.max_interim_responses)
                        return error.TooManyInterimResponses;
                    std.mem.copyForwards(
                        u8,
                        read_head.wire.items[0 .. read_head.wire.items.len - consumed_len],
                        read_head.wire.items[consumed_len..],
                    );
                    read_head.wire.items.len -= consumed_len;
                    read_head.scan_start = 0;
                    continue;
                }
                const wire = read_head.wire;
                self.response = .{ .allocator = self.allocator, .wire = wire, .head = head };
                self.state = .route_head;
                return null;
            }

            var chunk: [8192]u8 = undefined;
            switch (try connection.readStep(&chunk)) {
                .ready => |read_len| {
                    if (read_len == 0)
                        return error.FetchResponseTruncated;
                    self.head_progress.response_bytes_received = true;
                    self.wire_bytes.addReceived(read_len);
                    try read_head.wire.appendSlice(self.allocator, chunk[0..read_len]);
                },
                .eof => return error.FetchResponseTruncated,
                .wait => |interest| return .{ .io = .{
                    .interest = interest,
                    .timeout_err = error.FetchReadTimeout,
                } },
            }
        }
    }

    /// Pooled-connection replay, at most once per exchange, as undici and Bun
    /// do it: when a reused connection dies before any response byte, an
    /// idempotent request without a body is retried on a fresh dial. The dead
    /// attempt bills nothing; its ciphertext stays as cost.
    fn retryHeadOrFail(self: *Exchange, err: anyerror) anyerror!Need {
        const lease = &(self.lease orelse return err);
        if (self.retry_used or
            !lease.from_pool or
            !Http1Pool.isHttp1RetryableBeforeResponse(self.plan.?.method, self.request_body) or
            !http1_client.isHttp1ConnectionDeathBeforeResponse(err, self.head_progress))
            return err;
        self.retry_used = true;
        self.cost_bytes +|= lease.connection.takeWireBytes().total();
        self.wire_bytes = .{};
        self.head_progress = .{};
        switch (self.state) {
            .write_head => |*write_state| write_state.deinit(self.allocator),
            .read_head => |*read_head| read_head.deinit(self.allocator),
            else => {},
        }
        lease.deinit();
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
            self.url,
            self.method,
            self.headers,
            self.request_body,
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
            self.url,
            self.redirect_count != 0,
        );
        self.state = .publish_pending;
        return .{ .publish_head = &self.published_head.? };
    }

    fn isHeadRequest(self: *const Exchange) bool {
        return std.mem.eql(u8, self.plan.?.method, "HEAD");
    }

    fn initDrainFraming(self: *Exchange, drain: *Drain) void {
        const head = &self.response.?.head;
        if (self.isHeadRequest() or head.body_framing == .none)
            return; // no body: drained and reusable
        switch (head.body_framing) {
            .none => unreachable,
            .content_length => {
                if (head.content_length > self.config.max_redirect_drain_bytes or
                    head.post_head_bytes.len > head.content_length)
                    return drain.abandon();
                appendResponseChunk(
                    self.allocator,
                    &drain.body,
                    head.initial_body_bytes,
                    self.config.max_redirect_drain_bytes,
                ) catch return drain.abandon();
                drain.framing = .{ .content_length = head.content_length - head.initial_body_bytes.len };
                if (drain.framing.content_length == 0)
                    drain.framing = .done;
            },
            .close_delimited => {
                appendResponseChunk(
                    self.allocator,
                    &drain.body,
                    head.initial_body_bytes,
                    self.config.max_redirect_drain_bytes,
                ) catch return drain.abandon();
                drain.framing = .close_delimited;
            },
            .http1_chunked => {
                var decoder = http1.ChunkedDecoder{};
                const decoded = decoder.decode(
                    self.allocator,
                    head.initial_body_bytes,
                    &drain.body,
                    .{
                        .max_output_bytes = self.config.max_redirect_drain_bytes,
                        .max_wire_bytes = self.config.max_redirect_drain_bytes,
                    },
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
        const connection = &self.lease.?.connection;
        while (drain.framing != .done) {
            var chunk: [8192]u8 = undefined;
            const cap: usize = switch (drain.framing) {
                .content_length => |remaining| @min(chunk.len, remaining),
                else => chunk.len,
            };
            const step = connection.readStep(chunk[0..cap]) catch {
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
            // Drained redirect bodies are billed, since the client asked for
            // the chain; max_redirect_drain_bytes caps them.
            self.wire_bytes.addReceived(read_len);
            switch (drain.framing) {
                .done => unreachable,
                .content_length => |remaining| {
                    appendResponseChunk(
                        self.allocator,
                        &drain.body,
                        chunk[0..read_len],
                        self.config.max_redirect_drain_bytes,
                    ) catch {
                        drain.abandon();
                        break;
                    };
                    if (remaining == read_len)
                        drain.framing = .done
                    else
                        drain.framing = .{ .content_length = remaining - read_len };
                },
                .close_delimited => {
                    appendResponseChunk(
                        self.allocator,
                        &drain.body,
                        chunk[0..read_len],
                        self.config.max_redirect_drain_bytes,
                    ) catch {
                        drain.abandon();
                        break;
                    };
                },
                .chunked => |*decoder| {
                    const decoded = decoder.decode(
                        self.allocator,
                        chunk[0..read_len],
                        &drain.body,
                        .{
                            .max_output_bytes = self.config.max_redirect_drain_bytes,
                            .max_wire_bytes = self.config.max_redirect_drain_bytes,
                        },
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

        // Hop end: settle the connection, then hand the redirect out.
        if (!drain.abandoned) {
            var lease = &self.lease.?;
            self.cost_bytes +|= lease.connection.takeWireBytes().total();
            const reusable = drain.clean_for_pool and
                http1_wire.responseReusableForPool(self.response.?.head);
            if (reusable) {
                const hint_ns = keepAliveTimeoutNs(self.response.?.head.headers);
                try self.pool.put(&self.plan.?, self.config, lease, monotonicNowNs(), hint_ns);
                self.lease = null;
            }
        }
        if (self.lease) |*lease|
            self.cost_bytes +|= lease.connection.takeWireBytes().total();
        const redirect = drain.redirect.?;
        drain.redirect = null;
        var finished = self.state.drain_redirect;
        finished.deinit(self.allocator);
        self.state = .finished;
        return .{ .redirect = redirect };
    }

    fn absoluteBilled(self: *const Exchange) accounting.Bytes {
        return .{
            .sent = self.base.billed_sent +| self.wire_bytes.sent,
            .received = self.base.billed_received +| self.wire_bytes.received,
        };
    }

    fn foldMetersIntoBodyPipe(self: *Exchange) void {
        const billed = self.absoluteBilled();
        self.body_pipe.setEgressMeters(.{
            .billed_sent = billed.sent,
            .billed_received = billed.received,
            .cost = self.base.cost +| self.cost_bytes,
        });
    }

    /// Settles a terminal failure: absorbs the connection's final ciphertext
    /// delta and folds base plus attempt totals into the body pipe, the only
    /// carrier of a failed fetch's meters, as foldH2PendingMetersIntoBody
    /// does for HTTP/2. The fold is a monotonic max per field, so repeating
    /// it is harmless. The request head and body were counted when the write
    /// was prepared and may already be on the wire, so a failure before the
    /// response head still bills them. A replayed attempt already reset
    /// `wire_bytes`, so its billed bytes stay dropped and only its ciphertext
    /// remains as cost.
    ///
    /// A failure or cancel before the head and body write finished bills only
    /// the written prefix (`WriteState.writtenPrefix`), not the count taken
    /// when the write was prepared: an origin that stalled after accepting
    /// 128 KiB of an 8 MiB POST must not be billed 8 MiB, and billed must not
    /// exceed cost where cost is observable. HTTP/2 likewise bills each DATA
    /// write, never the queued remainder. Once the write finished
    /// (`.read_head` onward) the prepared count equals the written count.
    pub fn settleFailureMeters(self: *Exchange) void {
        switch (self.state) {
            .write_head => |*write_state| self.wire_bytes.sent = write_state.writtenPrefix(),
            // prepareWrite bills before the WriteState exists; a failure in
            // between (an allocation) wrote nothing.
            .prep_write => self.wire_bytes.sent = 0,
            else => {},
        }
        if (self.lease) |*lease|
            self.cost_bytes +|= lease.connection.takeWireBytes().total();
        self.foldMetersIntoBodyPipe();
    }

    fn finishAfterPublish(self: *Exchange) !Need {
        const lease = &self.lease.?;
        self.cost_bytes +|= lease.connection.takeWireBytes().total();
        self.foldMetersIntoBodyPipe();

        const head = &self.response.?.head;
        const response_encoding = http1_client.responseEncodingForHead(head.*) catch |err| {
            self.foldMetersIntoBodyPipe();
            http1_body.failFetchBody(self.body_pipe, self.allocator, @errorName(err));
            self.state = .finished;
            return .done;
        };

        const head_request = self.isHeadRequest();
        const headless = head_request or head.body_framing == .none;

        var return_ticket: ?http1_client.ConnectionReturn = null;
        if (http1_wire.responseReusableForPool(head.*)) {
            if (Http1Pool.Key.init(self.pool.allocator, &self.plan.?, self.config)) |key| {
                return_ticket = .{
                    .pool = self.pool,
                    .key = key,
                    .config = self.config,
                    .created_mono_ns = lease.created_mono_ns,
                    .requests_served = lease.requests_served,
                    .keep_alive_hint_ns = keepAliveTimeoutNs(head.headers),
                };
            } else |_| {}
        }
        errdefer if (return_ticket) |*ticket|
            ticket.discard();

        const continuation = try Continuation.init(
            self.allocator,
            self.pool,
            lease.connection,
            self.response.?,
            self.absoluteBilled(),
            self.base.cost +| self.cost_bytes,
            self.resume_source_id,
            head_request,
            response_encoding,
            self.config.http1StreamPumpLimits(),
            self.config,
            self.body_pipe,
            self.ready_ctx,
            self.ready_fn,
            self.ready_event,
            return_ticket,
        );
        // Ownership of the connection and response moved into the continuation.
        self.lease = null;
        self.response = null;
        // A HEAD or bodiless response has no body, so bytes read after its
        // head are dropped; a framed body keeps them as its first bytes.
        if (headless)
            continuation.pending_input = &.{};
        self.state = .finished;
        return .{ .body = continuation };
    }
};

fn monotonicNowNs() u64 {
    return readiness.monotonicNowNs() catch std.math.maxInt(u64);
}
