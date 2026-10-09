//! Harness for the HTTP/1 client tests here and the engine tests in
//! client/all.zig: drivers for the exchange and the body continuation, and a
//! local origin whose routes each provoke one protocol or billing case.
//!
//! The drivers stand in for the owner loop (drive, park on poll(2), resume)
//! and for a connector thread (policy resolve and dial on `.connect`), and
//! follow redirects as the engine's followH1Redirect does: the hop's meters
//! go into the cross-hop base and a fresh exchange starts.

const std = @import("std");
const local_address = @import("collo_test_net");
const egress_client = @import("collo_egress_client");
pub const transport = egress_client.transport;
pub const decompress = transport.decompress;
pub const fetch_body = egress_client.fetch_body;
const body_credit = egress_client.body_credit;

pub const Http1HeaderContext = struct {
    expected_url: []const u8,
    published: bool = false,
};

pub fn publishHttp1Head(context: *Http1HeaderContext, head: transport.StreamedResponseHead) !void {
    context.published = true;
    try std.testing.expectEqual(@as(u16, 200), head.status);
    try std.testing.expectEqualStrings(context.expected_url, head.url);
}

pub fn makeBodyPipe(allocator: std.mem.Allocator, capacity: usize) !*fetch_body.Body {
    const Identity = @TypeOf(@as(fetch_body.Body, undefined).identity);
    const body_pipe = try allocator.create(fetch_body.Body);
    body_pipe.* = fetch_body.Body.initOpen(allocator, std.mem.zeroes(Identity), capacity);
    return body_pipe;
}

pub fn releaseBodyPipe(body_pipe: *fetch_body.Body, allocator: std.mem.Allocator) void {
    body_pipe.releaseQueuedChunksCallback(allocator, {}, dropBodyCredit);
    body_pipe.releaseAfterQueuedResourcesReleased(allocator);
}

pub fn dropBodyCredit(context: void, credit: body_credit.Handle) void {
    _ = context;
    _ = credit;
}

/// Concatenated queued decoded bytes; nothing consumes the pipe in these
/// tests, so the queue holds the whole body.
pub fn collectBodyBytes(body_pipe: *fetch_body.Body, allocator: std.mem.Allocator) ![]u8 {
    body_pipe.mutex.lock();
    defer body_pipe.mutex.unlock();
    var out = std.array_list.Aligned(u8, null).empty;
    errdefer out.deinit(allocator);
    for (body_pipe.chunks.items[body_pipe.chunks_head..]) |chunk|
        try out.appendSlice(allocator, chunk.bytes);
    return out.toOwnedSlice(allocator);
}

pub fn bodyBilledTotal(body_pipe: *fetch_body.Body) u64 {
    const meters = body_pipe.egressMetersTotal();
    return meters.billed_sent +| meters.billed_received;
}

pub fn bodyCost(body_pipe: *fetch_body.Body) u64 {
    return body_pipe.egressMetersTotal().cost;
}

pub fn noopBodyReady(ctx: ?*anyopaque, event: transport.BodyReadyEvent) void {
    _ = ctx;
    _ = event;
}

/// One HTTP/1 fetch through the production exchange and continuation,
/// driven to body completion.
pub fn fetchViaExchange(
    allocator: std.mem.Allocator,
    pool: *transport.Http1Pool,
    dns: *transport.DnsCache,
    url: []const u8,
    method: []const u8,
    request_body: []const u8,
    headers: []const transport.Header,
    config: transport.Config,
    options: transport.FetchOptions,
    body_pipe: *fetch_body.Body,
    context: *Http1HeaderContext,
) !void {
    const continuation = (try runExchange(
        allocator,
        pool,
        dns,
        url,
        method,
        request_body,
        headers,
        config,
        options,
        body_pipe,
        context,
    )) orelse return;
    try driveContinuationToEnd(continuation);
}

/// Drives the exchange until it hands off a body continuation (`.body`) or
/// finishes without one (`.done`, returned as null), following redirects like
/// the engine. An error settles the exchange's failure meters first, as
/// failH1PendingAt does.
pub fn runExchange(
    allocator: std.mem.Allocator,
    pool: *transport.Http1Pool,
    dns: *transport.DnsCache,
    url: []const u8,
    method: []const u8,
    request_body: []const u8,
    headers: []const transport.Header,
    config: transport.Config,
    options: transport.FetchOptions,
    body_pipe: *fetch_body.Body,
    context: *Http1HeaderContext,
) !?*transport.Http1BodyContinuation {
    var current_url = try allocator.dupe(u8, url);
    defer allocator.free(current_url);
    var current_method = try allocator.dupe(u8, method);
    defer allocator.free(current_method);
    var current_headers = try transport.cloneHeaders(allocator, headers);
    defer transport.freeHeaders(allocator, current_headers);
    var current_body = request_body;
    var base = transport.Http1Exchange.BaseMeters{};
    var redirect_count: usize = 0;

    hop: while (true) {
        const exchange = try transport.Http1Exchange.init(
            allocator,
            pool,
            current_url,
            current_method,
            current_body,
            current_headers,
            config,
            options,
            redirect_count,
            base,
            1,
            body_pipe,
            null,
            noopBodyReady,
            .generic,
        );
        defer exchange.deinit();

        while (true) {
            const need = exchange.drive(.{}) catch |err| {
                _ = exchange.settleFailureMeters();
                return err;
            };
            switch (need) {
                .connect => {
                    const connection = dialForExchange(
                        allocator,
                        dns,
                        current_url,
                        current_method,
                        current_headers,
                        config,
                    ) catch |err| {
                        _ = exchange.settleFailureMeters();
                        return err;
                    };
                    exchange.adoptConnection(connection);
                },
                .io => |io| {
                    const fd = exchange.connectionFd() orelse {
                        _ = exchange.settleFailureMeters();
                        return error.FetchWriteFailed;
                    };
                    if (waitFdReadiness(fd, io.interest, config.socket_timeout_ms))
                        continue;
                    // On stall expiry a drain park only abandons reuse and
                    // any other park fails the fetch, as in expireH1Pending.
                    if (io.on_expire == .abandon_reuse) {
                        exchange.abandonRedirectDrain();
                        continue;
                    }
                    _ = exchange.settleFailureMeters();
                    return io.timeout_err;
                },
                .publish_head => |head| {
                    publishHttp1Head(context, head.*) catch |err| {
                        _ = exchange.settleFailureMeters();
                        return err;
                    };
                    exchange.markPublished();
                },
                .redirect => |redirect| {
                    const hop_billed = exchange.hopBilled();
                    base.billed_sent +|= hop_billed.sent;
                    base.billed_received +|= hop_billed.received;
                    base.cost +|= exchange.hopCost();
                    allocator.free(current_url);
                    allocator.free(current_method);
                    transport.freeHeaders(allocator, current_headers);
                    current_url = redirect.url;
                    current_method = redirect.method;
                    current_headers = redirect.headers;
                    current_body = redirect.body;
                    redirect_count += 1;
                    continue :hop;
                },
                .body => |continuation| return continuation,
                .done => return null,
            }
        }
    }
}

/// Steps the continuation as driveOneH1 does: a fresh drive budget per step,
/// a yield loops back, and `.done` folds the meters and returns the
/// connection. The probe is backed by a readiness driver, so a read inside
/// step() blocks under the stage deadline (socket_timeout_ms, then
/// FetchReadTimeout). With an empty probe every wait returns at once, so the
/// read loop would spin forever against a silent origin and hang the suite.
///
/// This driver blocks on purpose, which suits tests that check body bytes
/// and billing. It does not take the owner's would-block path, where a read
/// unwinds with error.EgressWouldBlock and the request re-parks (driveOneH1
/// in engine/h2_engine.zig); tests of that contract use
/// `driveContinuationOwnerShaped`.
pub fn driveContinuationToEnd(continuation: *transport.Http1BodyContinuation) !void {
    var driver = egress_client.readiness.Driver.init(std.testing.allocator);
    defer driver.deinit();
    const probe = transport.CancelProbe{ .driver = &driver };
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > 100_000) {
            continuation.failAndDeinit("harness continuation runaway");
            return error.HarnessContinuationRunaway;
        }
        var budget = transport.Http1DriveBudget{};
        const outcome = continuation.step(probe, &budget) catch |err| {
            continuation.failAndDeinit(@errorName(err));
            return err;
        };
        switch (outcome) {
            .done => break,
            .yielded => {},
            .paused => {
                continuation.failAndDeinit("unexpected pause");
                return error.UnexpectedBodyPause;
            },
        }
    }
    continuation.foldMetersIntoBody();
    continuation.returnConnectionIfReusable();
    continuation.deinit();
}

/// Interest of every would-block park `driveContinuationOwnerShaped` took,
/// in order. The first `interests.len` are kept and `parks` keeps counting.
/// On TLS any re-park can ask for either direction (a read can need write
/// readiness), so the mask-change test asserts on this sequence.
pub const OwnerShapedParkLog = struct {
    interests: [64]transport.IoInterest = undefined,
    parks: usize = 0,
    /// Incremented on every recorded park, so a test peer (the paced origin,
    /// a drain thread) can hold its next move until the client has really
    /// parked instead of sleeping and guessing when the park happened.
    park_signal: ?*std.atomic.Value(usize) = null,

    pub fn record(self: *OwnerShapedParkLog, interest: transport.IoInterest) void {
        if (self.parks < self.interests.len)
            self.interests[self.parks] = interest;
        self.parks += 1;
        if (self.park_signal) |signal|
            _ = signal.fetchAdd(1, .acq_rel);
    }

    pub fn recorded(self: *const OwnerShapedParkLog) []const transport.IoInterest {
        return self.interests[0..@min(self.parks, self.interests.len)];
    }
};

/// Drives a body continuation the way driveOneH1's `.body` arm does
/// (engine/h2_engine.zig): each step gets a would-block probe, so a read
/// that would block unwinds with error.EgressWouldBlock instead of blocking
/// inside step(); the driver then polls on the interest that park recorded,
/// with a fresh stall window per park as parkH1Io gives, and re-enters with
/// a fresh drive budget. This covers what `driveContinuationToEnd` cannot:
/// poll re-arming across parks, the interest of each park, and stall expiry
/// on the would-block path, which fails the fetch with the park's recorded
/// stage error as expireH1Pending does.
pub fn driveContinuationOwnerShaped(
    continuation: *transport.Http1BodyContinuation,
    socket_timeout_ms: u32,
    park_log: ?*OwnerShapedParkLog,
) !void {
    // The engine dials through a connector's readiness probe and its
    // connections stay nonblocking. This harness dials with an empty probe,
    // which falls back to `connectWithTimeout` (blocking fd plus
    // SO_RCVTIMEO), whose reads would sleep through pacing gaps instead of
    // unwinding, so the fd is switched to the mode the owner drives.
    transport.setFdNonblocking(continuation.connection.fd(), true) catch |err| {
        continuation.failAndDeinit(@errorName(err));
        return err;
    };
    var steps: usize = 0;
    while (true) {
        steps += 1;
        if (steps > 100_000) {
            continuation.failAndDeinit("harness continuation runaway");
            return error.HarnessContinuationRunaway;
        }
        // A fresh would-block slot and a fresh budget per re-entry, as the
        // owner records park info per wait and re-drives with a new budget.
        var park_info = transport.CancelProbe.WouldBlock{};
        const probe = transport.CancelProbe{ .would_block = &park_info };
        var budget = transport.Http1DriveBudget{};
        const outcome = continuation.step(probe, &budget) catch |err| {
            if (err != error.EgressWouldBlock) {
                continuation.failAndDeinit(@errorName(err));
                return err;
            }
            if (park_log) |log|
                log.record(park_info.interest);
            if (!waitFdReadiness(continuation.connection.fd(), park_info.interest, socket_timeout_ms)) {
                const timeout_err = park_info.timeout_err;
                continuation.failAndDeinit(@errorName(timeout_err));
                return timeout_err;
            }
            continue;
        };
        switch (outcome) {
            .done => break,
            .yielded => {},
            .paused => {
                continuation.failAndDeinit("unexpected pause");
                return error.UnexpectedBodyPause;
            },
        }
    }
    continuation.foldMetersIntoBody();
    continuation.returnConnectionIfReusable();
    continuation.deinit();
}

/// What a connector thread does for an HTTP/1 dial (completeH1Connect):
/// resolve under the policy, then connect. Every hop dials through here, so
/// the policy is checked again on each one.
fn dialForExchange(
    allocator: std.mem.Allocator,
    dns: *transport.DnsCache,
    url: []const u8,
    method: []const u8,
    headers: []const transport.Header,
    config: transport.Config,
) !transport.HttpConnection {
    var plan = try transport.prepareRequest(allocator, url, method, headers, config);
    defer plan.deinit();
    const policy = transport.EgressPolicy{
        .allow_plain_http = config.allow_plain_http,
        .allow_private_networks = config.allow_private_networks,
    };
    var target = try policy.resolveRequestTargetUntil(
        allocator,
        dns,
        plan.target,
        config.request_deadline_mono_ns,
    );
    defer target.deinit(allocator);
    return transport.connectWithProbe(allocator, target, config, .{});
}

/// Blocking stand-in for the owner's io-park: true on readiness, false on
/// the stall timeout.
fn waitFdReadiness(fd: std.posix.fd_t, interest: transport.IoInterest, timeout_ms: u32) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = if (interest == .read) std.posix.POLL.IN else std.posix.POLL.OUT,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch return false;
    return ready != 0;
}

/// Body size served by the `/big` route: large enough that the drive budget
/// (`drive_budget_max_bytes` per drive) must yield several times before EOF.
pub const big_body_bytes: usize = 1024 * 1024;

/// `/paced` route shape: several paced bursts, each small enough that the
/// client drains it in one read and then would-block until the next.
pub const paced_chunk_bytes: usize = 8 * 1024;
pub const paced_chunk_count: usize = 6;
pub const paced_body_bytes: usize = paced_chunk_bytes * paced_chunk_count;

pub fn containsHeader(headers: []const transport.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name))
            return true;
    }
    return false;
}

pub const LocalHttp1Origin = struct {
    server: std.net.Server,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread,
    accepted: std.atomic.Value(usize),
    request_wire: std.atomic.Value(u64),
    response_wire: std.atomic.Value(u64),
    stopping: std.atomic.Value(bool),
    /// `/paced` chunk gate: chunk N is written only once this counter
    /// reaches N. A test points `OwnerShapedParkLog.park_signal` here, so the
    /// counter is the client's recorded park count and pacing never depends
    /// on a sleep.
    paced_gate: std.atomic.Value(usize),

    pub fn start(allocator: std.mem.Allocator) !*LocalHttp1Origin {
        var host_buffer: [64]u8 = undefined;
        const host_len = try routableLocalIpv4(&host_buffer);
        var address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const origin = try allocator.create(LocalHttp1Origin);
        errdefer allocator.destroy(origin);
        origin.* = .{
            .server = server,
            .host_buffer = host_buffer,
            .host_len = host_len,
            .port = server.listen_address.getPort(),
            .thread = undefined,
            .accepted = std.atomic.Value(usize).init(0),
            .request_wire = std.atomic.Value(u64).init(0),
            .response_wire = std.atomic.Value(u64).init(0),
            .stopping = std.atomic.Value(bool).init(false),
            .paced_gate = std.atomic.Value(usize).init(0),
        };
        origin.thread = try std.Thread.spawn(.{}, LocalHttp1Origin.threadMain, .{origin});
        return origin;
    }

    pub fn host(self: *const LocalHttp1Origin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    pub fn stop(self: *LocalHttp1Origin, allocator: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        if (std.net.Address.parseIp(self.host(), self.port)) |address| {
            if (std.net.tcpConnectToAddress(address)) |stream|
                stream.close()
            else |_| {}
        } else |_| {}
        self.thread.join();
        self.server.deinit();
        allocator.destroy(self);
    }

    fn threadMain(self: *LocalHttp1Origin) void {
        while (!self.stopping.load(.acquire)) {
            var connection = self.server.accept() catch return;
            _ = self.accepted.fetchAdd(1, .acq_rel);
            self.handleConnection(connection.stream);
            connection.stream.close();
        }
    }

    fn handleConnection(self: *LocalHttp1Origin, stream: std.net.Stream) void {
        var buffer: [2048]u8 = undefined;
        var requests_served: usize = 0;
        while (true) {
            const received = readHttpRequest(stream, &buffer) catch return;
            if (received.len == 0)
                return;
            _ = self.request_wire.fetchAdd(@intCast(received.len), .acq_rel);
            const is_one = std.mem.containsAtLeast(u8, received, 1, "POST /one HTTP/1.1");
            const is_two = std.mem.containsAtLeast(u8, received, 1, "POST /two HTTP/1.1");
            const is_gzip = std.mem.containsAtLeast(u8, received, 1, "POST /gzip HTTP/1.1");
            const is_stall = std.mem.containsAtLeast(u8, received, 1, "GET /stall HTTP/1.1");
            const is_stale = std.mem.containsAtLeast(u8, received, 1, "GET /stale HTTP/1.1");
            const is_ambiguous = std.mem.containsAtLeast(u8, received, 1, "GET /ambiguous HTTP/1.1");
            const is_redirect_loopback = std.mem.containsAtLeast(u8, received, 1, "GET /redirect-loopback HTTP/1.1");
            const is_hop = std.mem.containsAtLeast(u8, received, 1, "GET /hop HTTP/1.1");
            const is_hop_final = std.mem.containsAtLeast(u8, received, 1, "GET /hop-final HTTP/1.1");
            const is_empty_post = std.mem.containsAtLeast(u8, received, 1, "POST /empty HTTP/1.1");
            const is_stale_post = std.mem.containsAtLeast(u8, received, 1, "POST /stale-post HTTP/1.1");
            const is_ka_zero = std.mem.containsAtLeast(u8, received, 1, "GET /ka-zero HTTP/1.1");
            const is_hang_second = std.mem.containsAtLeast(u8, received, 1, "GET /hang-second HTTP/1.1");
            const is_interim_flood = std.mem.containsAtLeast(u8, received, 1, "GET /interim-flood HTTP/1.1");
            const is_interim_ok = std.mem.containsAtLeast(u8, received, 1, "GET /interim-ok HTTP/1.1");
            const is_interim_only = std.mem.containsAtLeast(u8, received, 1, "GET /interim-only HTTP/1.1");
            const is_bare_lf_keepalive = std.mem.containsAtLeast(u8, received, 1, "GET /bare-lf-keepalive HTTP/1.1");
            const is_bare_lf = std.mem.containsAtLeast(u8, received, 1, "GET /bare-lf HTTP/1.1");
            const is_big = std.mem.containsAtLeast(u8, received, 1, "GET /big HTTP/1.1");
            const is_endless = std.mem.containsAtLeast(u8, received, 1, "GET /endless HTTP/1.1");
            const is_paced = std.mem.containsAtLeast(u8, received, 1, "GET /paced HTTP/1.1");
            const is_stall_mid = std.mem.containsAtLeast(u8, received, 1, "GET /stall-mid HTTP/1.1");
            const is_black_hole = std.mem.containsAtLeast(u8, received, 1, "POST /black-hole HTTP/1.1");
            if (is_big) {
                // Large body for the fairness tests, written as fast as the
                // peer drains it, so only the client's drive budget breaks up
                // the transfer.
                var head: [128]u8 = undefined;
                const response_head = std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
                    .{big_body_bytes},
                ) catch return;
                _ = self.response_wire.fetchAdd(@intCast(response_head.len + big_body_bytes), .acq_rel);
                stream.writeAll(response_head) catch return;
                const chunk = [_]u8{'b'} ** 4096;
                var remaining: usize = big_body_bytes;
                while (remaining != 0) {
                    const write_len = @min(remaining, chunk.len);
                    stream.writeAll(chunk[0..write_len]) catch return;
                    remaining -= write_len;
                }
                return;
            }
            if (is_endless) {
                // Close-delimited body written as fast as the peer drains
                // it, until the origin stops or the client closes the
                // connection. A request streaming it stays runnable,
                // yielding its budget and never reaching EOF, for the whole
                // test: the head-of-line load for the turn-budget tests. Wire
                // meters are not kept; no billing test uses this route.
                const response_head = "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n";
                stream.writeAll(response_head) catch return;
                // 64 KiB writes keep the syscall rate from bounding the
                // stream. The turn-budget tests need each socket to hold a
                // full drive budget of bytes when the owner returns to it;
                // otherwise drives end in would-block parks instead of
                // spending their budget.
                const chunk = [_]u8{'e'} ** (64 * 1024);
                while (!self.stopping.load(.acquire))
                    stream.writeAll(&chunk) catch return;
                return;
            }
            if (is_paced) {
                // Small body sent in bursts, so the client's read would
                // block between chunks and the owner-shaped driver goes
                // through several park and re-park rounds. Every chunk after
                // the first waits for the client's recorded park count
                // (`paced_gate`, fed by OwnerShapedParkLog.park_signal): the
                // socket is dry when the client parks and is refilled only
                // after, so the number of parks is deterministic.
                var head: [128]u8 = undefined;
                const chunk = [_]u8{'p'} ** paced_chunk_bytes;
                const total = paced_chunk_bytes * paced_chunk_count;
                const response_head = std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
                    .{total},
                ) catch return;
                _ = self.response_wire.fetchAdd(@intCast(response_head.len + total), .acq_rel);
                stream.writeAll(response_head) catch return;
                for (0..paced_chunk_count) |chunk_index| {
                    while (chunk_index != 0 and self.paced_gate.load(.acquire) < chunk_index) {
                        // The client died or the test is ending: nobody will
                        // advance the gate, so the origin thread must not
                        // wait on it.
                        if (self.stopping.load(.acquire))
                            return;
                        std.Thread.sleep(1 * std.time.ns_per_ms);
                    }
                    stream.writeAll(&chunk) catch return;
                }
                return;
            }
            if (is_stall_mid) {
                // Head plus part of the body, then silence without closing,
                // so the client's per-park stall window expires mid-body on
                // the owner-shaped driver's would-block path. The wait is
                // bounded so a wedged client cannot hold the origin thread
                // past the test.
                const response_head = "HTTP/1.1 200 OK\r\ncontent-length: 128\r\nconnection: close\r\n\r\n";
                _ = self.response_wire.fetchAdd(response_head.len + 32, .acq_rel);
                stream.writeAll(response_head) catch return;
                stream.writeAll(&[_]u8{'m'} ** 32) catch return;
                var waited_ms: usize = 0;
                while (!self.stopping.load(.acquire) and waited_ms < 2_000) : (waited_ms += 5)
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                return;
            }
            if (is_black_hole) {
                // Take the upload, then go silent without closing, so the
                // client's read stall timeout fires with the request bytes
                // already on the wire: the billing case of a failure before
                // the response head. The wait is bounded so a wedged client
                // cannot hold the origin thread past the test.
                var waited_ms: usize = 0;
                while (!self.stopping.load(.acquire) and waited_ms < 2_000) : (waited_ms += 5)
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                return;
            }
            if (is_empty_post) {
                const body: []const u8 = if (std.mem.containsAtLeast(u8, received, 1, "content-length: 0"))
                    "empty ok"
                else
                    "empty bad";
                self.writeSimpleResponse(stream, body, "close") catch return;
                return;
            }
            if (is_stale_post) {
                self.writeSimpleResponse(stream, "stale ok", "keep-alive") catch return;
                return;
            }
            if (is_ka_zero) {
                var head: [160]u8 = undefined;
                const body = "ka ok";
                const response_head = std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nkeep-alive: timeout=0\r\nconnection: keep-alive\r\n\r\n",
                    .{body.len},
                ) catch return;
                _ = self.response_wire.fetchAdd(@intCast(response_head.len + body.len), .acq_rel);
                stream.writeAll(response_head) catch return;
                stream.writeAll(body) catch return;
                requests_served += 1;
                continue;
            }
            if (is_hang_second) {
                if (requests_served != 0) {
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    return;
                }
                self.writeSimpleResponse(stream, "hang ok", "keep-alive") catch return;
                requests_served += 1;
                continue;
            }
            if (is_interim_only) {
                // Only interim heads, one past the client's cap, then close
                // without a final response. Every byte the client reads
                // belongs to a 1xx head, so the billing test can expect
                // exactly zero billed_received whatever the packet
                // boundaries.
                const interim = "HTTP/1.1 100 Continue\r\n\r\n";
                for (0..9) |_| {
                    _ = self.response_wire.fetchAdd(interim.len, .acq_rel);
                    stream.writeAll(interim) catch return;
                }
                return;
            }
            if (is_interim_flood or is_interim_ok) {
                const interim = "HTTP/1.1 100 Continue\r\n\r\n";
                const interim_count: usize = if (is_interim_flood) 9 else 2;
                for (0..interim_count) |_| {
                    _ = self.response_wire.fetchAdd(interim.len, .acq_rel);
                    stream.writeAll(interim) catch return;
                }
                self.writeSimpleResponse(stream, "interim ok", "close") catch return;
                return;
            }
            if (is_bare_lf) {
                const response = "HTTP/1.1 200 OK\ncontent-length: 5\nconnection: close\n\nlf ok";
                _ = self.response_wire.fetchAdd(response.len, .acq_rel);
                stream.writeAll(response) catch return;
                return;
            }
            if (is_bare_lf_keepalive) {
                const response = "HTTP/1.1 200 OK\ncontent-length: 5\nconnection: keep-alive\n\nlf ok";
                _ = self.response_wire.fetchAdd(response.len, .acq_rel);
                stream.writeAll(response) catch return;
                requests_served += 1;
                continue;
            }
            const ok = std.mem.containsAtLeast(u8, received, 1, "POST /data HTTP/1.1") and
                std.mem.containsAtLeast(u8, received, 1, "x-collo-test: yes") and
                std.mem.containsAtLeast(u8, received, 1, "\r\n\r\npayload");
            const gzip_body = [_]u8{
                0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
                0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
                0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
            };
            if (is_ambiguous) {
                const response =
                    "HTTP/1.1 200 OK\r\n" ++
                    "content-length: 2\r\n" ++
                    "transfer-encoding: chunked\r\n" ++
                    "connection: close\r\n" ++
                    "\r\n" ++
                    "0\r\n\r\n";
                _ = self.response_wire.fetchAdd(response.len, .acq_rel);
                stream.writeAll(response) catch return;
                return;
            }
            if (is_hop) {
                // Redirect hop with a small body; the drained body must show
                // up in the billed total summed over the chain.
                var response: [224]u8 = undefined;
                const hop_body = "moved";
                const response_wire = std.fmt.bufPrint(
                    &response,
                    "HTTP/1.1 302 Found\r\nlocation: http://{s}:{d}/hop-final\r\ncontent-length: {d}\r\nconnection: keep-alive\r\n\r\n{s}",
                    .{ self.host(), self.port, hop_body.len, hop_body },
                ) catch return;
                _ = self.response_wire.fetchAdd(@intCast(response_wire.len), .acq_rel);
                stream.writeAll(response_wire) catch return;
                requests_served += 1;
                continue;
            }
            if (is_hop_final) {
                self.writeSimpleResponse(stream, "final ok", "close") catch return;
                return;
            }
            if (is_redirect_loopback) {
                var response: [192]u8 = undefined;
                const response_wire = std.fmt.bufPrint(
                    &response,
                    "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:{d}/one\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                    .{self.port},
                ) catch return;
                _ = self.response_wire.fetchAdd(@intCast(response_wire.len), .acq_rel);
                stream.writeAll(response_wire) catch return;
                return;
            }
            const stall_body = [_]u8{'s'} ** 64;
            const body = if (is_gzip)
                gzip_body[0..]
            else if (is_stall)
                stall_body[0..]
            else if (is_one)
                "one ok"
            else if (is_two)
                "two ok"
            else if (is_stale)
                "stale ok"
            else if (ok)
                "post ok"
            else
                "bad";
            const close_header = !(is_one or is_stale);
            const close_after_write = close_header or is_stale;
            var head: [128]u8 = undefined;
            const response_head = std.fmt.bufPrint(
                &head,
                "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\n{s}connection: {s}\r\n\r\n",
                .{ body.len, if (is_gzip) "content-encoding: gzip\r\n" else "", if (close_header) "close" else "keep-alive" },
            ) catch return;
            _ = self.response_wire.fetchAdd(@intCast(response_head.len + body.len), .acq_rel);
            stream.writeAll(response_head) catch return;
            stream.writeAll(body) catch return;
            if (close_after_write)
                return;
            requests_served += 1;
        }
    }

    fn writeSimpleResponse(
        self: *LocalHttp1Origin,
        stream: std.net.Stream,
        body: []const u8,
        connection_value: []const u8,
    ) !void {
        var head: [128]u8 = undefined;
        const response_head = try std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: {s}\r\n\r\n",
            .{ body.len, connection_value },
        );
        _ = self.response_wire.fetchAdd(@intCast(response_head.len + body.len), .acq_rel);
        try stream.writeAll(response_head);
        try stream.writeAll(body);
    }

    fn readHttpRequest(stream: std.net.Stream, buffer: []u8) ![]const u8 {
        var received_len: usize = 0;
        var body_end: ?usize = null;
        while (received_len < buffer.len) {
            const amount = stream.read(buffer[received_len..]) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            if (amount == 0)
                break;
            received_len += amount;
            if (body_end == null) {
                if (std.mem.indexOf(u8, buffer[0..received_len], "\r\n\r\n")) |header_end| {
                    const headers = buffer[0..header_end];
                    const body_start = header_end + 4;
                    body_end = body_start + parseContentLength(headers);
                }
            }
            if (body_end) |end| {
                if (received_len >= end)
                    break;
            }
        }
        return buffer[0..received_len];
    }

    fn parseContentLength(headers: []const u8) usize {
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
            if (!std.ascii.eqlIgnoreCase(name, "content-length"))
                continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
            return std.fmt.parseInt(usize, value, 10) catch 0;
        }
        return 0;
    }
};

fn routableLocalIpv4(out: *[64]u8) !usize {
    const host = try local_address.routableLocalIpv4(out);
    return host.len;
}
