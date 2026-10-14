//! Harness for the HTTP/1 client tests here and the engine tests in
//! client/all.zig: a stand-in for one engine owner loop that drives the
//! production exchange and body continuation over the production io_uring
//! data driver, and a local origin whose routes each provoke one protocol
//! case.
//!
//! `Client` holds what an engine shard holds for HTTP/1: the data driver and
//! the pool, whose hooks go to the driver the way the owner's do: a dropped
//! wire is released through it, and a wire about to be leased is refreshed
//! by it. The drivers follow `engine/h1.zig`: one plan per hop, prepared
//! under the fetch's network policy and kept until the hop ends; a dial on
//! `.connect`, with its TLS handshake stepped on driver waits for an https
//! origin; every wait on a wire under a fresh stall deadline of
//! `socket_timeout_ms`; a redirect followed on a new exchange whose plan
//! decides the next hop. A dial skips DNS, since every origin here is an IPv4
//! literal and the literal is the whole answer, but that address still passes
//! the hop's admission. Tests skip when the kernel offers no restricted
//! io_uring.
//!
//! The origin serves on this host's routable address, and its `policy`
//! admits that address on the origin's port alone, so a redirect to any
//! other port or host is refused before a connection opens. It serves one
//! connection at a time, so a test releases a kept-alive wire before it
//! needs a second connection.

const std = @import("std");
const local_address = @import("collo_test_net");
const egress_client = @import("collo_egress_client");
const network_policy = @import("../network_policy.zig");

pub const transport = egress_client.transport;
pub const decompress = transport.decompress;
pub const data_io = egress_client.data_io;

const core = egress_client.core;
const IoInterest = transport.IoInterest;
const ResponseQueue = core.ResponseQueue;
const Wire = transport.Wire;

/// Bound on the drives of one hop and the steps of one continuation; a
/// harness loop past it means the code under test stopped making progress.
const max_drive_steps: usize = 100_000;
/// Bound on the driver waits within one stall window. A wait returns at
/// least every watchdog tick, so no window here comes near it.
const max_wait_rounds: usize = 4096;
/// Bound on the pulls that empty one response queue.
const max_queue_pulls: usize = 1 << 20;
/// The most pooled wires `Client.serviceIdleEntries` watches at once: the
/// default `Config.http1_pool_max_entries`.
const max_idle_watches: usize = 16;
/// The resume-credit source of every fetch here; nothing routes the credits.
const body_source_id: u64 = 1;
const body_identity: core.FetchBodyIdentity = .{
    .request_id = 1,
    .request_generation = 1,
    .fetch_id = 1,
    .body_id = 1,
};

/// What one engine shard holds for HTTP/1: the data driver and the pool. The
/// pool's hooks point at `driver`, so a `Client` is initialized in place and
/// never moves; `deinit` empties the pool before the driver goes.
pub const Client = struct {
    allocator: std.mem.Allocator,
    driver: data_io.Driver,
    pool: transport.Http1Pool,

    /// Skips the test when this kernel or its policy offers no restricted
    /// io_uring; any other failure fails it.
    pub fn init(self: *Client, allocator: std.mem.Allocator) !void {
        const driver = data_io.Driver.init(allocator) catch |err| switch (err) {
            error.UnsupportedKernel, error.PermissionDenied => return error.SkipZigTest,
            else => |other| return other,
        };
        self.* = .{
            .allocator = allocator,
            .driver = driver,
            .pool = transport.Http1Pool.init(allocator, .{
                .context = &self.driver,
                .release_fn = releaseWire,
                .refresh_fn = refreshWire,
            }),
        };
    }

    pub fn deinit(self: *Client) void {
        self.pool.deinit();
        self.driver.deinit();
        self.* = undefined;
    }

    /// Stands in for the owner parked on `wire`: driver waits for `interest`
    /// until one reports progress or `timeout_ms` of silence passes. Returns
    /// true on progress (a receive fed the wire or a send drained it), false
    /// at the stall deadline, and fails with the error the driver recorded
    /// for the wire, which fails the fetch in the engine too.
    pub fn serviceWire(self: *Client, wire: *Wire, interest: IoInterest, timeout_ms: u32) !bool {
        var context: u8 = 0;
        const source: data_io.Source = .{
            .context = &context,
            .io = .{ .wire = wire },
            .deadline_mono_ns = try transport.config.deadlineAfterMs(timeout_ms),
            .want_read = interest == .read,
            .want_write = interest == .write,
        };
        for (0..max_wait_rounds) |_| {
            switch (try self.driver.wait(&.{source}, null)) {
                .ready => return true,
                .expired => return false,
                .failed => |failure| return failure.err,
                // A watchdog tick or a wake says nothing about this wire.
                .wake, .tick => {},
            }
        }
        return error.HarnessWaitRunaway;
    }

    /// Watches every pooled wire through the receive the engine keeps armed
    /// on it (`Http1Pool.idleEntries`) until one completes or `timeout_ms`
    /// passes, then evicts what that made unusable, as the owner does when
    /// an idle wire's watch fires. Returns whether a completion arrived.
    pub fn serviceIdleEntries(self: *Client, timeout_ms: u32) !bool {
        const entries = self.pool.idleEntries();
        if (entries.len == 0)
            return false;
        if (entries.len > max_idle_watches)
            return error.HarnessTooManyIdleEntries;
        var context: u8 = 0;
        const deadline_mono_ns = try transport.config.deadlineAfterMs(timeout_ms);
        var sources: [max_idle_watches]data_io.Source = undefined;
        for (entries, sources[0..entries.len]) |entry, *source| {
            source.* = .{
                .context = &context,
                .io = .{ .wire = entry.wire },
                .deadline_mono_ns = @min(deadline_mono_ns, entry.expires_mono_ns),
                .want_read = true,
            };
        }
        for (0..max_wait_rounds) |_| {
            const arrived = switch (try self.driver.wait(sources[0..entries.len], null)) {
                .ready, .failed => true,
                .expired => false,
                .wake, .tick => continue,
            };
            self.pool.evictUnusable(try transport.config.monotonicNowNs());
            return arrived;
        }
        return error.HarnessWaitRunaway;
    }

    /// Waits until the socket of the one pooled wire has something to read,
    /// bytes or its peer's close, without taking it: at most `timeout_ms`.
    pub fn awaitIdleSocketReadable(self: *Client, timeout_ms: i32) !void {
        const entries = self.pool.idleEntries();
        if (entries.len != 1)
            return error.HarnessExpectedOneIdleEntry;
        var polled = [_]std.posix.pollfd{.{
            .fd = entries[0].wire.fd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&polled, timeout_ms) == 0)
            return error.HarnessIdleSocketNeverReadable;
    }

    /// Waits until the driver's ring holds the completion of the receive
    /// armed on the one pooled wire, at most `gate_wait_ms_max`, and leaves
    /// it unread with every completion posted before it, so the lease is
    /// what ingests them. A ring that holds something says nothing about the
    /// receive: the wait that armed it leaves its own timeout's completion
    /// unread once the deadline cuts its drain short, and the timeout
    /// removal that ends the wait posts another.
    pub fn awaitIdleReceivePosted(self: *Client) !void {
        const entries = self.pool.idleEntries();
        if (entries.len != 1)
            return error.HarnessExpectedOneIdleEntry;
        const receive_user_data = self.receiveInFlight(entries[0].wire) orelse
            return error.HarnessIdleReceiveNotArmed;
        for (0..gate_wait_ms_max) |_| {
            if (self.completionPosted(receive_user_data))
                return;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        return error.HarnessCompletionNeverPosted;
    }

    /// The user data of the receive the driver holds in flight on `wire`,
    /// read from the wire's registration, or null when it holds none.
    fn receiveInFlight(self: *const Client, wire: *Wire) ?u64 {
        for (self.driver.registrations.items) |registration| {
            switch (registration.target) {
                .wire => |registered| {
                    if (registered == wire and registration.recv_queued)
                        return registration.recv_user_data;
                },
                .none, .connecting => {},
            }
        }
        return null;
    }

    /// Whether a completion carrying `user_data` sits between the ring's
    /// head and tail. It reads the entries in place and leaves the head where
    /// it is, so the driver still ingests every one of them.
    fn completionPosted(self: *const Client, user_data: u64) bool {
        const queue = &self.driver.ring.cq;
        const head = queue.head.*;
        const posted: usize = @min(@atomicLoad(u32, queue.tail, .acquire) -% head, queue.cqes.len);
        for (0..posted) |offset| {
            const position = head +% @as(u32, @intCast(offset));
            if (queue.cqes[position & queue.mask].user_data == user_data)
                return true;
        }
        return false;
    }

    /// Dials `plan`'s origin as `engine/dial.zig` does once DNS answered:
    /// the address passes the hop's admission, a nonblocking connect runs
    /// under the driver's connect watch, and the socket becomes a wire the
    /// caller owns. An https origin's wire offers http/1.1 alone, as an
    /// HTTP/1 fetch's own dial does, and is handshaken before it returns.
    pub fn dial(self: *Client, plan: *const transport.RequestPlan, config: transport.Config) !*Wire {
        const address = try std.net.Address.parseIp(plan.target.tls_server_name, plan.target.port);
        try transport.admitResolvedAddresses(plan.target.admission, &.{address});
        const attempt = try transport.connect.startAttempt(address);
        self.awaitConnect(attempt, config.socket_timeout_ms) catch |err| {
            std.posix.close(attempt.fd);
            return err;
        };
        const stream: std.net.Stream = .{ .handle = attempt.fd };
        switch (plan.target.protocol) {
            .plain => return Wire.createPlain(self.allocator, stream, config.wire_buffer_bytes),
            .tls => {
                const wire = try Wire.createTls(self.allocator, stream, .{
                    .server_name = plan.target.tls_server_name,
                    .insecure_tls = config.insecure_tls,
                    .session_key = null,
                    .offer_h2 = false,
                }, config.wire_buffer_bytes);
                errdefer releaseWire(&self.driver, wire);
                try self.handshake(wire, config.socket_timeout_ms);
                return wire;
            },
        }
    }

    /// Steps `wire`'s TLS handshake as `engine/dial.zig:stepHandshake` does,
    /// each step after the driver serviced the interest the last one named,
    /// under a fresh stall window.
    fn handshake(self: *Client, wire: *Wire, timeout_ms: u32) !void {
        for (0..max_drive_steps) |_| {
            switch (try wire.handshakeStep()) {
                .done => return,
                .wait => |interest| {
                    if (!try self.serviceWire(wire, interest, timeout_ms))
                        return error.TlsHandshakeTimeout;
                },
            }
        }
        return error.HarnessHandshakeRunaway;
    }

    fn awaitConnect(self: *Client, attempt: transport.connect.StartedAttempt, timeout_ms: u32) !void {
        if (!attempt.connected) {
            var context: u8 = 0;
            const source: data_io.Source = .{
                .context = &context,
                .io = .{ .connecting = attempt.fd },
                .deadline_mono_ns = try transport.config.deadlineAfterMs(timeout_ms),
            };
            // The watch ends before the socket is adopted or closed, as in
            // `engine/dial.zig:attemptReady`.
            defer self.driver.cancelConnecting(attempt.fd);
            for (0..max_wait_rounds) |_| {
                switch (try self.driver.wait(&.{source}, null)) {
                    // A connect poll reports every outcome as readiness; the
                    // socket's own error tells which.
                    .ready, .failed => break,
                    .expired => return error.FetchConnectTimeout,
                    .wake, .tick => {},
                }
            } else return error.HarnessWaitRunaway;
        }
        try transport.connect.finishAttempt(attempt.fd);
    }
};

/// The pool's release hook: frees a dropped wire once the driver lets go of
/// it, or leaves it to the driver, which frees it after its last completion,
/// as `engine/owner.zig:releaseWire` does.
fn releaseWire(context: ?*anyopaque, wire: *Wire) void {
    const driver: *data_io.Driver = @ptrCast(@alignCast(context.?));
    if (driver.cancelConnectionForClose(wire))
        wire.deinit();
}

/// The pool's refresh hook: the driver brings a wire about to be leased up
/// to date with its socket.
fn refreshWire(context: ?*anyopaque, wire: *Wire) bool {
    const driver: *data_io.Driver = @ptrCast(@alignCast(context.?));
    return driver.refreshIdleWire(wire);
}

fn noopBodyReady(context: ?*anyopaque, event: transport.BodyReadyEvent) void {
    _ = context;
    _ = event;
}

fn dropCredit(context: void, credit: core.body_credit.Handle) void {
    _ = context;
    _ = credit;
}

/// One fetch's response as a test sees it: whether its head was published,
/// the queue its body streams into, and the body bytes pulled from that
/// queue so far. A fetch borrows the queue, so a `Response` stays where it
/// was initialized while a fetch runs; `deinit` drops what is still queued.
pub const Response = struct {
    /// The URL the published head must name: the last hop's.
    expected_url: []const u8,
    /// The status the published head must carry.
    expected_status: u16 = 200,
    queue: ResponseQueue,
    published: bool = false,
    body: std.array_list.Aligned(u8, null) = .empty,

    pub fn init(expected_url: []const u8) Response {
        return .{
            .expected_url = expected_url,
            .queue = ResponseQueue.init(body_identity, null),
        };
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
        self.queue.releaseQueued(allocator, {}, dropCredit);
        self.queue.deinit(allocator);
        self.* = undefined;
    }

    /// Pulls every chunk the queue holds into `body`, as the gateway loop's
    /// pulls do, and returns the queue's state after the last pull: `.open`
    /// when more may come. A failed queue drops what it still held.
    pub fn pull(self: *Response, allocator: std.mem.Allocator) !core.response_queue.State {
        for (0..max_queue_pulls) |_| {
            _ = self.queue.armPull();
            const pulled = self.queue.pull(allocator);
            if (pulled.bytes) |bytes| {
                defer allocator.free(bytes);
                try self.body.appendSlice(allocator, bytes);
            }
            if (pulled.done)
                return .complete;
            if (pulled.failed)
                return .failed;
            if (pulled.isEmpty())
                return .open;
        }
        return error.HarnessQueueRunaway;
    }

    /// Expects the body to have completed as `expected`.
    pub fn expectBody(self: *Response, allocator: std.mem.Allocator, expected: []const u8) !void {
        try std.testing.expectEqual(core.response_queue.State.complete, try self.pull(allocator));
        try std.testing.expectEqualStrings(expected, self.body.items);
    }

    fn publish(self: *Response, head: *const transport.StreamedResponseHead) !void {
        self.published = true;
        try std.testing.expectEqual(self.expected_status, head.status);
        try std.testing.expectEqualStrings(self.expected_url, head.url);
    }
};

/// One fetch as a test names it; everything is borrowed for the call.
pub const Request = struct {
    url: []const u8,
    method: []const u8 = "GET",
    body: []const u8 = "",
    headers: []const transport.Header = &.{},
    options: transport.FetchOptions = .{},
};

/// One HTTP/1 fetch through the production exchange and continuation,
/// driven to the end of its body.
pub fn fetchViaExchange(
    client: *Client,
    request: Request,
    config: transport.Config,
    response: *Response,
) !void {
    const continuation = (try runExchange(client, request, config, response)) orelse return;
    try driveContinuationToEnd(client, continuation, response, config.socket_timeout_ms, null);
}

/// Drives the exchange until it hands off a body continuation (`.body`) or
/// ends without one (`.done`, returned as null). A redirect is followed as
/// `engine/h1.zig:followRedirect` does: its target becomes the next hop's
/// request, prepared into a new plan under the same config, with the body
/// kept or dropped as the redirect says.
pub fn runExchange(
    client: *Client,
    request: Request,
    config: transport.Config,
    response: *Response,
) !?*transport.Http1BodyContinuation {
    const allocator = client.allocator;
    var url = try allocator.dupe(u8, request.url);
    defer allocator.free(url);
    var method = try allocator.dupe(u8, request.method);
    defer allocator.free(method);
    var headers = try transport.cloneHeaders(allocator, request.headers);
    defer transport.freeHeaders(allocator, headers);
    var body = request.body;

    for (0..request.options.max_redirects + 1) |redirect_count| {
        const hop_end = try runHop(client, .{
            .url = url,
            .method = method,
            .headers = headers,
            .body = body,
            .options = request.options,
            .redirect_count = redirect_count,
        }, config, response);
        switch (hop_end) {
            .body => |continuation| return continuation,
            .done => return null,
            .redirect => |redirect| {
                allocator.free(url);
                allocator.free(method);
                transport.freeHeaders(allocator, headers);
                url = redirect.url;
                method = redirect.method;
                headers = redirect.headers;
                switch (redirect.body) {
                    .keep => {},
                    .drop => body = "",
                }
            },
        }
    }
    return error.HarnessRedirectRunaway;
}

const Hop = struct {
    url: []const u8,
    method: []const u8,
    headers: []const transport.Header,
    body: []const u8,
    options: transport.FetchOptions,
    redirect_count: usize,
};

const HopEnd = union(enum) {
    /// The caller owns the target's url, method and headers.
    redirect: transport.RedirectTarget,
    body: *transport.Http1BodyContinuation,
    done,
};

/// One hop as `engine/h1.zig:drive` runs it. The plan outlives the exchange
/// that borrows it, and the exchange is freed when the hop ends, after its
/// continuation took the wire or its redirect handed out the target.
fn runHop(client: *Client, hop: Hop, config: transport.Config, response: *Response) !HopEnd {
    var plan = try transport.prepareRequest(client.allocator, hop.url, hop.method, hop.headers, config);
    defer plan.deinit();
    const exchange = try transport.Http1Exchange.init(
        client.allocator,
        &client.pool,
        &plan,
        hop.body,
        config,
        hop.options,
        hop.redirect_count,
        body_source_id,
        &response.queue,
        null,
        noopBodyReady,
        .generic,
    );
    defer exchange.deinit();

    for (0..max_drive_steps) |_| {
        switch (try exchange.drive()) {
            .connect => exchange.adoptConnection(try client.dial(&plan, config)),
            .io => |io| {
                const wire = exchange.connectionWire() orelse return error.FetchWriteFailed;
                if (try client.serviceWire(wire, io.interest, config.socket_timeout_ms))
                    continue;
                // At the stall deadline a redirect drain gives up only the
                // wire's reuse, and any other wait fails the fetch, as
                // `engine/h1.zig:expired` decides.
                switch (io.on_expire) {
                    .abandon_reuse => exchange.abandonRedirectDrain(),
                    .fail_fetch => return io.timeout_err,
                }
            },
            .publish_head => |head| {
                try response.publish(head);
                exchange.markPublished();
            },
            .redirect => |redirect| return .{ .redirect = redirect },
            .body => |continuation| return .{ .body = continuation },
            .done => return .done,
        }
    }
    return error.HarnessExchangeRunaway;
}

/// What a continuation's `.wait` steps asked for, in order: the first
/// `interests.len` are kept and `waits` counts them all. `signal`, when
/// set, is bumped at every wait before the harness services the wire, so a
/// test origin can hold its next write until the client really waits.
pub const WaitLog = struct {
    interests: [64]IoInterest = undefined,
    waits: usize = 0,
    signal: ?*std.atomic.Value(usize) = null,

    pub fn record(self: *WaitLog, interest: IoInterest) void {
        if (self.waits < self.interests.len)
            self.interests[self.waits] = interest;
        self.waits += 1;
        if (self.signal) |signal|
            _ = signal.fetchAdd(1, .acq_rel);
    }

    pub fn recorded(self: *const WaitLog) []const IoInterest {
        return self.interests[0..@min(self.waits, self.interests.len)];
    }
};

/// Steps a body continuation as `engine/h1.zig:drive` does. `.wait`
/// services the wire for the interest it names under a fresh stall window;
/// `.paused` pulls the queued chunks into `response`, as the gateway loop's
/// pulls make room; `.done` finishes it, which offers a clean wire to the
/// pool. A failure or the stall deadline ends it with `failAndDeinit` and
/// returns the error, as the engine ends the fetch.
pub fn driveContinuationToEnd(
    client: *Client,
    continuation: *transport.Http1BodyContinuation,
    response: *Response,
    socket_timeout_ms: u32,
    wait_log: ?*WaitLog,
) !void {
    for (0..max_drive_steps) |_| {
        const step = continuation.step() catch |err| {
            continuation.failAndDeinit(@errorName(err));
            return err;
        };
        switch (step) {
            .done => {
                continuation.finish();
                return;
            },
            .paused => {
                _ = response.pull(client.allocator) catch |err| {
                    continuation.failAndDeinit(@errorName(err));
                    return err;
                };
            },
            .wait => |interest| {
                if (wait_log) |log|
                    log.record(interest);
                const progressed = client.serviceWire(continuation.wire, interest, socket_timeout_ms) catch |err| {
                    continuation.failAndDeinit(@errorName(err));
                    return err;
                };
                if (!progressed) {
                    continuation.failAndDeinit(@errorName(error.FetchReadTimeout));
                    return error.FetchReadTimeout;
                }
            },
        }
    }
    continuation.failAndDeinit("harness continuation runaway");
    return error.HarnessContinuationRunaway;
}

pub fn containsHeader(headers: []const transport.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name))
            return true;
    }
    return false;
}

/// Body size of the `/big` and `/big-held` routes: enough receives that a
/// fetch streaming it shares the owner loop with the fetches around it.
pub const big_body_bytes: usize = 1024 * 1024;
/// What `/big-held` sends of its body before it holds the rest.
pub const big_held_first_bytes: usize = big_body_bytes / 2;

/// `/paced` body: chunks small enough that the client takes each in one
/// receive and then waits for the next.
pub const paced_chunk_bytes: usize = 8 * 1024;
pub const paced_chunk_count: usize = 6;
pub const paced_body_bytes: usize = paced_chunk_bytes * paced_chunk_count;

/// `/stall-mid` sends this much of its declared body, then goes silent.
pub const stall_mid_prefix_bytes: usize = 32;
const stall_mid_body_bytes: usize = 128;

/// The body of `/surplus` and `/surplus-inline`, and the bytes they send
/// after it: a stray response head, which a reused wire would hand the next
/// request as its response. `/stray-later` sends the same head after its
/// own response.
pub const surplus_body = "lucky";
const surplus_trailer = "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n";
/// The body of `/stray-later`'s response.
pub const stray_later_body = "stray ok";
/// The body `/close-second` and `/reset-second` answer the first request on
/// a connection with.
pub const kept_body = "kept ok";

/// Interim heads the `/interim-flood` route sends: one past the client's
/// cap (`http1/message.zig:max_interim_responses`).
const interim_flood_count: usize = 9;
const interim_ok_count: usize = 2;
/// `/stall` body size.
const stall_body_bytes: usize = 64;
/// How long `/hang-second` withholds its second answer, past every read
/// deadline the tests set.
const hang_ms: u64 = 500;
/// The longest a silent route holds its connection, so a wedged client
/// cannot hold the origin thread past the test.
const silence_ms_max: usize = 2_000;
/// How often a silent route checks whether the origin stops.
const silence_step_ms: usize = 5;
/// The longest a gated write waits for the test to open the gate.
const gate_wait_ms_max: usize = 5_000;
/// Requests one connection may carry before the origin closes it.
const max_requests_per_connection: usize = 64;

const gzip_hello_world = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
    0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
};

const Route = enum {
    data,
    one,
    fast,
    gzip,
    stall,
    stale,
    empty,
    ambiguous,
    redirect_loopback,
    hop,
    hop_final,
    ka_zero,
    hang_second,
    interim_flood,
    interim_ok,
    bare_lf,
    bare_lf_keepalive,
    big,
    big_held,
    paced,
    stall_mid,
    surplus,
    surplus_inline,
    no_content_surplus,
    stray_later,
    close_second,
    reset_second,
};

const routes = std.StaticStringMap(Route).initComptime(.{
    .{ "/data", .data },
    .{ "/one", .one },
    .{ "/fast", .fast },
    .{ "/gzip", .gzip },
    .{ "/stall", .stall },
    .{ "/stale", .stale },
    .{ "/empty", .empty },
    .{ "/ambiguous", .ambiguous },
    .{ "/redirect-loopback", .redirect_loopback },
    .{ "/hop", .hop },
    .{ "/hop-final", .hop_final },
    .{ "/ka-zero", .ka_zero },
    .{ "/hang-second", .hang_second },
    .{ "/interim-flood", .interim_flood },
    .{ "/interim-ok", .interim_ok },
    .{ "/bare-lf", .bare_lf },
    .{ "/bare-lf-keepalive", .bare_lf_keepalive },
    .{ "/big", .big },
    .{ "/big-held", .big_held },
    .{ "/paced", .paced },
    .{ "/stall-mid", .stall_mid },
    .{ "/surplus", .surplus },
    .{ "/surplus-inline", .surplus_inline },
    .{ "/no-content-surplus", .no_content_surplus },
    .{ "/stray-later", .stray_later },
    .{ "/close-second", .close_second },
    .{ "/reset-second", .reset_second },
});

/// `struct linger` of `SO_LINGER`, which the standard library does not
/// declare.
const Linger = extern struct {
    onoff: c_int,
    seconds: c_int,
};

/// What a response's `connection` header says, and separately what the
/// origin does after it.
const Connection = enum { close, keep_alive };

/// A plain-HTTP origin on its own thread. Each route answers one protocol
/// case:
///
/// - `/data` (POST with `x-collo-test: yes` and body `payload`), `/fast`,
///   `/gzip` (a gzip body), `/stall` and `/hop-final` answer once and
///   close; `/one` keeps the connection.
/// - `/stale` promises keep-alive and closes anyway; `/hang-second`
///   answers the first request on a connection and stays silent on the
///   second; `/close-second` and `/reset-second` answer the first and, on
///   the second, close the connection, with a FIN or a reset, without
///   answering; `/ka-zero` sends `Keep-Alive: timeout=0`.
/// - `/empty` reports whether the request said `content-length: 0`;
///   `/ambiguous` frames its body two ways; `/interim-flood` and
///   `/interim-ok` precede the answer with interim heads; `/bare-lf` and
///   `/bare-lf-keepalive` end lines with a bare LF.
/// - `/hop` redirects to `/hop-final` with a small body, keeping the
///   connection; `/redirect-loopback` redirects to 127.0.0.1;
///   `/redirect-port/<port>` redirects to `/one` on another port.
/// - `/big` streams `big_body_bytes`; `/big-held` sends `big_held_first_bytes`
///   of the same body and holds the rest until `releaseHeldBody`; `/paced`
///   sends its chunks through the gate; `/stall-mid` stops partway through
///   its body; `/surplus` sends its head, then after the gate opens its body
///   and a stray head in one write; `/surplus-inline` sends head, body and
///   stray head in one write, and `/no-content-surplus` a 204 head and a
///   stray head; `/stray-later` answers in full, keeping the connection,
///   and sends a stray head once the gate opens.
/// - Anything else answers "bad" and closes.
pub const LocalHttp1Origin = struct {
    server: std.net.Server,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread,
    accepted: std.atomic.Value(usize),
    stopping: std.atomic.Value(bool),
    /// Write gate of `/paced`, `/surplus` and `/stray-later`: a route's
    /// gated write N waits until this counter reaches N. A test advances it
    /// from what the client did (a recorded wait, a parsed head, a finished
    /// response), so a route's pacing never rests on a sleep.
    gate: std.atomic.Value(usize),
    /// `/big-held`: set once the first `big_held_first_bytes` were written,
    /// and set by `releaseHeldBody` to let the rest go.
    held_body_first_sent: std.atomic.Value(bool),
    held_body_released: std.atomic.Value(bool),
    /// Backs `policy`, which points into it; the origin's heap address keeps
    /// it in place.
    origins: network_policy.Origins,

    pub fn start(allocator: std.mem.Allocator) !*LocalHttp1Origin {
        var host_buffer: [64]u8 = undefined;
        const host_len = (try local_address.routableLocalIpv4(&host_buffer)).len;
        const address = try std.net.Address.parseIp4("0.0.0.0", 0);
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
            .accepted = .init(0),
            .stopping = .init(false),
            .gate = .init(0),
            .held_body_first_sent = .init(false),
            .held_body_released = .init(false),
            .origins = .{},
        };
        try origin.origins.init(origin.host(), &.{origin.port});
        origin.thread = try std.Thread.spawn(.{}, LocalHttp1Origin.threadMain, .{origin});
        return origin;
    }

    pub fn host(self: *const LocalHttp1Origin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    /// `http://<host>:<port><path>`, which the caller frees.
    pub fn url(self: *const LocalHttp1Origin, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ self.host(), self.port, path });
    }

    /// Plain HTTP and HTTPS to this origin's address and port, and nowhere
    /// else. Valid until `stop`.
    pub fn policy(self: *const LocalHttp1Origin) transport.network.Policy {
        return self.origins.policy();
    }

    /// Whether `/big-held` has written the first `big_held_first_bytes` of
    /// its body and now holds the rest. The bytes may still be on their way
    /// to the client.
    pub fn heldBodyFirstSent(self: *const LocalHttp1Origin) bool {
        return self.held_body_first_sent.load(.acquire);
    }

    /// Lets `/big-held` send the rest of its body. Unreleased, the route
    /// gives up after `gate_wait_ms_max` and closes the connection, which
    /// truncates the body.
    pub fn releaseHeldBody(self: *LocalHttp1Origin) void {
        self.held_body_released.store(true, .release);
    }

    /// Joins the origin thread, which first finishes the connection it
    /// serves, so every client wire to it must be closed first.
    pub fn stop(self: *LocalHttp1Origin, allocator: std.mem.Allocator) void {
        self.stopping.store(true, .release);
        // A connection of its own wakes the accept the thread blocks in.
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
            const connection = self.server.accept() catch return;
            _ = self.accepted.fetchAdd(1, .acq_rel);
            self.handleConnection(connection.stream);
            connection.stream.close();
        }
    }

    fn handleConnection(self: *LocalHttp1Origin, stream: std.net.Stream) void {
        var buffer: [2048]u8 = undefined;
        for (0..max_requests_per_connection) |requests_served| {
            const request = readHttpRequest(stream, &buffer) catch return;
            if (request.len == 0)
                return;
            const after = self.respond(stream, request, requests_served) catch return;
            switch (after) {
                .close => return,
                .keep_alive => {},
            }
        }
    }

    /// Answers one request and says whether the connection stays open.
    fn respond(self: *LocalHttp1Origin, stream: std.net.Stream, request: []const u8, requests_served: usize) !Connection {
        var head: [256]u8 = undefined;
        if (redirectPort(request)) |target_port| {
            try stream.writeAll(try std.fmt.bufPrint(
                &head,
                "HTTP/1.1 302 Found\r\nlocation: http://{s}:{d}/one\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                .{ self.host(), target_port },
            ));
            return .close;
        }
        const route = routeOf(request) orelse {
            try writeResponse(stream, "bad", .close);
            return .close;
        };
        switch (route) {
            .data => {
                const ok = std.mem.startsWith(u8, request, "POST ") and
                    std.mem.indexOf(u8, request, "x-collo-test: yes") != null and
                    std.mem.indexOf(u8, request, "\r\n\r\npayload") != null;
                try writeResponse(stream, if (ok) "post ok" else "bad", .close);
                return .close;
            },
            .one => {
                try writeResponse(stream, "one ok", .keep_alive);
                return .keep_alive;
            },
            .fast => {
                try writeResponse(stream, "fast ok", .close);
                return .close;
            },
            .gzip => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\ncontent-encoding: gzip\r\nconnection: close\r\n\r\n",
                    .{gzip_hello_world.len},
                ));
                try stream.writeAll(&gzip_hello_world);
                return .close;
            },
            .stall => {
                try writeResponse(stream, &([_]u8{'s'} ** stall_body_bytes), .close);
                return .close;
            },
            .stale => {
                try writeResponse(stream, "stale ok", .keep_alive);
                return .close;
            },
            .empty => {
                const said_empty = std.mem.indexOf(u8, request, "content-length: 0") != null;
                try writeResponse(stream, if (said_empty) "empty ok" else "empty bad", .close);
                return .close;
            },
            .ambiguous => {
                try stream.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\ntransfer-encoding: chunked\r\n" ++
                    "connection: close\r\n\r\n0\r\n\r\n");
                return .close;
            },
            .redirect_loopback => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:{d}/one\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                    .{self.port},
                ));
                return .close;
            },
            .hop => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 302 Found\r\nlocation: http://{s}:{d}/hop-final\r\ncontent-length: 5\r\nconnection: keep-alive\r\n\r\nmoved",
                    .{ self.host(), self.port },
                ));
                return .keep_alive;
            },
            .hop_final => {
                try writeResponse(stream, "final ok", .close);
                return .close;
            },
            .ka_zero => {
                try stream.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 5\r\nkeep-alive: timeout=0\r\n" ++
                    "connection: keep-alive\r\n\r\nka ok");
                return .keep_alive;
            },
            .hang_second => {
                if (requests_served == 0) {
                    try writeResponse(stream, "hang ok", .keep_alive);
                    return .keep_alive;
                }
                std.Thread.sleep(hang_ms * std.time.ns_per_ms);
                return .close;
            },
            .interim_flood, .interim_ok => {
                const count = if (route == .interim_flood) interim_flood_count else interim_ok_count;
                for (0..count) |_|
                    try stream.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
                try writeResponse(stream, "interim ok", .close);
                return .close;
            },
            .bare_lf => {
                try stream.writeAll("HTTP/1.1 200 OK\ncontent-length: 5\nconnection: close\n\nlf ok");
                return .close;
            },
            .bare_lf_keepalive => {
                try stream.writeAll("HTTP/1.1 200 OK\ncontent-length: 5\nconnection: keep-alive\n\nlf ok");
                return .keep_alive;
            },
            .big => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
                    .{big_body_bytes},
                ));
                const chunk = [_]u8{'b'} ** 4096;
                comptime std.debug.assert(big_body_bytes % chunk.len == 0);
                for (0..big_body_bytes / chunk.len) |_|
                    try stream.writeAll(&chunk);
                return .close;
            },
            .big_held => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
                    .{big_body_bytes},
                ));
                const chunk = [_]u8{'b'} ** 4096;
                comptime std.debug.assert(big_held_first_bytes % chunk.len == 0);
                for (0..big_held_first_bytes / chunk.len) |_|
                    try stream.writeAll(&chunk);
                self.held_body_first_sent.store(true, .release);
                if (!self.awaitHeldBodyRelease())
                    return .close;
                for (0..(big_body_bytes - big_held_first_bytes) / chunk.len) |_|
                    try stream.writeAll(&chunk);
                return .close;
            },
            .paced => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
                    .{paced_body_bytes},
                ));
                const chunk = [_]u8{'p'} ** paced_chunk_bytes;
                for (0..paced_chunk_count) |chunk_index| {
                    if (!self.awaitGate(chunk_index))
                        return .close;
                    try stream.writeAll(&chunk);
                }
                return .close;
            },
            .stall_mid => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
                    .{stall_mid_body_bytes},
                ));
                try stream.writeAll(&([_]u8{'m'} ** stall_mid_prefix_bytes));
                self.holdSilent();
                return .close;
            },
            .surplus => {
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: keep-alive\r\n\r\n",
                    .{surplus_body.len},
                ));
                // The test opens the gate once the client parsed the head, so
                // the body and the stray head reach it in one later receive.
                if (!self.awaitGate(1))
                    return .close;
                try stream.writeAll(surplus_body ++ surplus_trailer);
                return .keep_alive;
            },
            .surplus_inline => {
                // One small write on a local socket reaches the client in
                // the receive that carries the head.
                try stream.writeAll(try std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: keep-alive\r\n\r\n" ++
                        surplus_body ++ surplus_trailer,
                    .{surplus_body.len},
                ));
                return .keep_alive;
            },
            .no_content_surplus => {
                try stream.writeAll("HTTP/1.1 204 No Content\r\nconnection: keep-alive\r\n\r\n" ++ surplus_trailer);
                return .keep_alive;
            },
            .stray_later => {
                try writeResponse(stream, stray_later_body, .keep_alive);
                // The test opens the gate once the client finished the
                // response, so the stray head reaches it in a later segment.
                if (!self.awaitGate(1))
                    return .close;
                try stream.writeAll(surplus_trailer);
                return .keep_alive;
            },
            .close_second, .reset_second => {
                if (requests_served == 0) {
                    try writeResponse(stream, kept_body, .keep_alive);
                    return .keep_alive;
                }
                // A zero linger makes the close that follows reset the
                // connection instead of ending it with a FIN.
                if (route == .reset_second) {
                    const linger: Linger = .{ .onoff = 1, .seconds = 0 };
                    try std.posix.setsockopt(
                        stream.handle,
                        std.posix.SOL.SOCKET,
                        std.posix.SO.LINGER,
                        std.mem.asBytes(&linger),
                    );
                }
                return .close;
            },
        }
    }

    /// Whether `gate` reached `count`: false when the origin stops or the
    /// test never opens the gate within `gate_wait_ms_max`.
    fn awaitGate(self: *LocalHttp1Origin, count: usize) bool {
        for (0..gate_wait_ms_max) |_| {
            if (self.gate.load(.acquire) >= count)
                return true;
            if (self.stopping.load(.acquire))
                return false;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        return false;
    }

    /// Whether the test released `/big-held`'s body: false when the origin
    /// stops or the test never releases it within `gate_wait_ms_max`.
    fn awaitHeldBodyRelease(self: *LocalHttp1Origin) bool {
        for (0..gate_wait_ms_max) |_| {
            if (self.held_body_released.load(.acquire))
                return true;
            if (self.stopping.load(.acquire))
                return false;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        return false;
    }

    /// Keeps the connection open and silent until the origin stops or
    /// `silence_ms_max` passes.
    fn holdSilent(self: *LocalHttp1Origin) void {
        for (0..silence_ms_max / silence_step_ms) |_| {
            if (self.stopping.load(.acquire))
                return;
            std.Thread.sleep(silence_step_ms * std.time.ns_per_ms);
        }
    }

    fn writeResponse(stream: std.net.Stream, body: []const u8, connection: Connection) !void {
        var head: [128]u8 = undefined;
        try stream.writeAll(try std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: {s}\r\n\r\n",
            .{ body.len, switch (connection) {
                .close => "close",
                .keep_alive => "keep-alive",
            } },
        ));
        try stream.writeAll(body);
    }

    /// Reads one request, head and Content-Length body, into `buffer`; empty
    /// when the client closed. The socket blocks, so every read makes
    /// progress or ends the request.
    fn readHttpRequest(stream: std.net.Stream, buffer: []u8) ![]const u8 {
        var received_len: usize = 0;
        var body_end: ?usize = null;
        while (received_len < buffer.len) {
            const amount = try stream.read(buffer[received_len..]);
            if (amount == 0)
                break;
            received_len += amount;
            if (body_end == null) {
                if (std.mem.indexOf(u8, buffer[0..received_len], "\r\n\r\n")) |header_end|
                    body_end = header_end + 4 + parseContentLength(buffer[0..header_end]);
            }
            if (body_end) |end| {
                if (received_len >= end)
                    break;
            }
        }
        return buffer[0..received_len];
    }

    fn routeOf(request: []const u8) ?Route {
        var parts = std.mem.splitScalar(u8, request, ' ');
        _ = parts.next() orelse return null;
        const target = parts.next() orelse return null;
        return routes.get(target);
    }

    /// The port of a `GET /redirect-port/<port>` request.
    fn redirectPort(request: []const u8) ?u16 {
        const prefix = "GET /redirect-port/";
        if (!std.mem.startsWith(u8, request, prefix))
            return null;
        const rest = request[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        return std.fmt.parseInt(u16, rest[0..end], 10) catch null;
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
