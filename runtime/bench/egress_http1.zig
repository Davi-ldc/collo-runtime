//! Measures HTTP/1 egress connection reuse and streaming body delivery
//! through the code the egress engine's owner loop runs, `Http1Exchange` and
//! its body continuation. A blocking loop on this process's main thread
//! stands in for the owner loop (drive, park in poll(2), resume) and dials
//! each `.connect` inline, as a connector thread would. For every sample a
//! local origin on its own thread serves one scenario: a closed connection
//! per request, keep-alive, or keep-alive with a gzip body. The driver
//! checks every decoded body byte for byte. Like every egress bench it builds
//! ReleaseFast without JSC.

const std = @import("std");
const bench_metadata = @import("metadata.zig");
const egress_client = @import("collo_egress_client");

const transport = egress_client.transport;
const fetch_body = egress_client.fetch_body;
const body_credit = egress_client.body_credit;

const default_iterations: usize = 5;
const default_requests: usize = 32;

const Scenario = enum {
    close,
    keep_alive,
    gzip_keep_alive,

    fn keepAlive(self: Scenario) bool {
        return self != .close;
    }

    fn gzip(self: Scenario) bool {
        return self == .gzip_keep_alive;
    }
};

const scenarios = [_]Scenario{ .close, .keep_alive, .gzip_keep_alive };

const Sample = struct {
    elapsed_ns: u64,
    ttfb_ns: u64,
    rss_kib: u64,
    peak_rss_kib: u64,
    accepted_connections: usize,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    try bench_metadata.print(allocator, "egress_http1");
    const iterations = try envUsize(allocator, "COLLO_BENCH_EGRESS_HTTP1_ITERATIONS", default_iterations);
    const requests = try envUsize(allocator, "COLLO_BENCH_EGRESS_HTTP1_REQUESTS", default_requests);

    for (scenarios) |scenario| {
        const elapsed_samples = try allocator.alloc(u64, iterations);
        defer allocator.free(elapsed_samples);
        const ttfb_samples = try allocator.alloc(u64, iterations);
        defer allocator.free(ttfb_samples);

        for (elapsed_samples, ttfb_samples, 0..) |*elapsed, *ttfb, iteration| {
            const sample = try runSample(allocator, scenario, requests);
            elapsed.* = sample.elapsed_ns;
            ttfb.* = sample.ttfb_ns;
            printJsonSample(scenario, iteration + 1, requests, sample);
        }

        std.mem.sort(u64, elapsed_samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, ttfb_samples, {}, std.sort.asc(u64));
        printSummary(scenario, requests, elapsed_samples, ttfb_samples);
    }
}

fn runSample(allocator: std.mem.Allocator, scenario: Scenario, requests: usize) !Sample {
    var origin = try LocalHttp1Origin.start(allocator, scenario, requests);
    defer origin.stop(allocator);

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/bench", .{ origin.host(), origin.port });
    defer allocator.free(url);

    var dns_cache = transport.DnsCache.init(allocator, .{});
    defer dns_cache.deinit();
    var pool = transport.Http1Pool.init(allocator);
    defer pool.deinit();

    const config = transport.Config{
        .allow_plain_http = true,
        .allow_private_networks = true,
        .max_response_body_bytes = 64 * 1024,
        .http1_pool_max_entries = 1,
        .http1_pool_max_requests_per_connection = if (scenario.keepAlive()) requests + 1 else 1,
    };

    const start_ns = try monotonicNowNs();
    var first_head_ns: ?u64 = null;
    var index: usize = 0;
    while (index < requests) : (index += 1) {
        const body_pipe = try makeBodyPipe(allocator, 64 * 1024);
        defer releaseBodyPipe(body_pipe, allocator);
        try performOne(allocator, &pool, &dns_cache, url, config, start_ns, &first_head_ns, body_pipe);
        if (!bodyHoldsExactly(body_pipe, "hello world"))
            return error.EgressHttp1BenchUnexpectedBody;
    }
    const elapsed_ns = (try monotonicNowNs()) - start_ns;
    const memory = readProcessMemory();
    return .{
        .elapsed_ns = elapsed_ns,
        .ttfb_ns = first_head_ns orelse elapsed_ns,
        .rss_kib = memory.rss_kib,
        .peak_rss_kib = memory.peak_rss_kib,
        .accepted_connections = origin.accepted.load(.acquire),
    };
}

/// Drives one exchange to completion the way the owner loop would, but blocks
/// where the owner loop parks: in poll(2) while the exchange waits on its
/// socket, and inside the body continuation's reads.
fn performOne(
    allocator: std.mem.Allocator,
    pool: *transport.Http1Pool,
    dns: *transport.DnsCache,
    url: []const u8,
    config: transport.Config,
    start_ns: u64,
    first_head_ns: *?u64,
    body_pipe: *fetch_body.Body,
) !void {
    const exchange = try transport.Http1Exchange.init(
        allocator,
        pool,
        url,
        "GET",
        "",
        &.{},
        config,
        .{},
        0,
        .{},
        1,
        body_pipe,
        null,
        noopBodyReady,
        .generic,
    );
    defer exchange.deinit();

    while (true) {
        const need = try exchange.drive(.{});
        switch (need) {
            .connect => exchange.adoptConnection(try dial(allocator, dns, url, config)),
            .io => |io| {
                const fd = exchange.connectionFd() orelse return error.FetchWriteFailed;
                if (!waitFdReadiness(fd, io.interest, config.socket_timeout_ms))
                    return io.timeout_err;
            },
            .publish_head => |head| {
                if (head.status != 200)
                    return error.UnexpectedHttpStatus;
                if (first_head_ns.* == null)
                    first_head_ns.* = (try monotonicNowNs()) - start_ns;
                exchange.markPublished();
            },
            .redirect => return error.UnexpectedRedirect,
            .body => |continuation| {
                // The probe carries a readiness driver, so a body read inside
                // step() blocks until the stage deadline; without it the read
                // would spin on would-block and never enforce
                // socket_timeout_ms. The owner loop instead unwinds
                // error.EgressWouldBlock and re-parks with a fresh budget on
                // each re-entry (`driveOneH1` in
                // egress/client/engine/h2_engine.zig). This bench measures
                // throughput and does not cover park semantics; the harness
                // in egress/tests/client/http1/support.zig covers the
                // would-block path.
                var body_driver = egress_client.readiness.Driver.init(allocator);
                defer body_driver.deinit();
                const body_probe = transport.CancelProbe{ .driver = &body_driver };
                while (true) {
                    var budget = transport.Http1DriveBudget{};
                    const outcome = continuation.step(body_probe, &budget) catch |err| {
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
                continuation.returnConnectionIfReusable();
                continuation.deinit();
                return;
            },
            .done => return,
        }
    }
}

fn dial(
    allocator: std.mem.Allocator,
    dns: *transport.DnsCache,
    url: []const u8,
    config: transport.Config,
) !transport.HttpConnection {
    var plan = try transport.prepareRequest(allocator, url, "GET", &.{}, config);
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

fn waitFdReadiness(fd: std.posix.fd_t, interest: transport.IoInterest, timeout_ms: u32) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = if (interest == .read) std.posix.POLL.IN else std.posix.POLL.OUT,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch return false;
    return ready != 0;
}

fn noopBodyReady(ctx: ?*anyopaque, event: transport.BodyReadyEvent) void {
    _ = ctx;
    _ = event;
}

fn makeBodyPipe(allocator: std.mem.Allocator, capacity: usize) !*fetch_body.Body {
    const Identity = @TypeOf(@as(fetch_body.Body, undefined).identity);
    const body_pipe = try allocator.create(fetch_body.Body);
    body_pipe.* = fetch_body.Body.initOpen(allocator, std.mem.zeroes(Identity), capacity);
    return body_pipe;
}

fn releaseBodyPipe(body_pipe: *fetch_body.Body, allocator: std.mem.Allocator) void {
    body_pipe.releaseQueuedChunksCallback(allocator, {}, dropBodyCredit);
    body_pipe.releaseAfterQueuedResourcesReleased(allocator);
}

fn dropBodyCredit(context: void, credit: body_credit.Handle) void {
    _ = context;
    _ = credit;
}

fn bodyHoldsExactly(body_pipe: *fetch_body.Body, expected: []const u8) bool {
    body_pipe.mutex.lock();
    defer body_pipe.mutex.unlock();
    var offset: usize = 0;
    for (body_pipe.chunks.items[body_pipe.chunks_head..]) |chunk| {
        if (offset + chunk.bytes.len > expected.len)
            return false;
        if (!std.mem.eql(u8, expected[offset..][0..chunk.bytes.len], chunk.bytes))
            return false;
        offset += chunk.bytes.len;
    }
    return offset == expected.len;
}

const LocalHttp1Origin = struct {
    server: std.net.Server,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread,
    scenario: Scenario,
    expected_requests: usize,
    served: std.atomic.Value(usize),
    accepted: std.atomic.Value(usize),
    stopping: std.atomic.Value(bool),

    fn start(allocator: std.mem.Allocator, scenario: Scenario, expected_requests: usize) !*LocalHttp1Origin {
        var host_buffer: [64]u8 = undefined;
        const host_len = try routableLocalIpv4(&host_buffer);
        var address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const origin = try allocator.create(LocalHttp1Origin);
        origin.* = .{
            .server = server,
            .host_buffer = host_buffer,
            .host_len = host_len,
            .port = server.listen_address.getPort(),
            .thread = undefined,
            .scenario = scenario,
            .expected_requests = expected_requests,
            .served = std.atomic.Value(usize).init(0),
            .accepted = std.atomic.Value(usize).init(0),
            .stopping = std.atomic.Value(bool).init(false),
        };
        origin.thread = try std.Thread.spawn(.{}, LocalHttp1Origin.threadMain, .{origin});
        return origin;
    }

    fn host(self: *const LocalHttp1Origin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    fn stop(self: *LocalHttp1Origin, allocator: std.mem.Allocator) void {
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
        while (!self.stopping.load(.acquire) and self.served.load(.acquire) < self.expected_requests) {
            var connection = self.server.accept() catch return;
            _ = self.accepted.fetchAdd(1, .acq_rel);
            self.handleConnection(connection.stream);
            connection.stream.close();
        }
    }

    fn handleConnection(self: *LocalHttp1Origin, stream: std.net.Stream) void {
        var buffer: [2048]u8 = undefined;
        while (!self.stopping.load(.acquire) and self.served.load(.acquire) < self.expected_requests) {
            const received = readHttpRequest(stream, &buffer) catch return;
            if (received.len == 0)
                return;
            const gzip_body = [_]u8{
                0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
                0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
                0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
            };
            const body = if (self.scenario.gzip()) gzip_body[0..] else "hello world";
            const close = !self.scenario.keepAlive();
            var head: [192]u8 = undefined;
            const response_head = std.fmt.bufPrint(
                &head,
                "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\n{s}connection: {s}\r\n\r\n",
                .{ body.len, if (self.scenario.gzip()) "content-encoding: gzip\r\n" else "", if (close) "close" else "keep-alive" },
            ) catch return;
            stream.writeAll(response_head) catch return;
            stream.writeAll(body) catch return;
            _ = self.served.fetchAdd(1, .acq_rel);
            if (close)
                return;
        }
    }
};

fn readHttpRequest(stream: std.net.Stream, buffer: []u8) ![]const u8 {
    var received_len: usize = 0;
    while (received_len < buffer.len) {
        const amount = try stream.read(buffer[received_len..]);
        if (amount == 0)
            break;
        received_len += amount;
        if (std.mem.indexOf(u8, buffer[0..received_len], "\r\n\r\n") != null)
            break;
    }
    return buffer[0..received_len];
}

// The egress policy denies loopback whatever allow_private_networks says, so
// the client reaches the origin, which listens on every address, through the
// default-route source address, as runtime/tests/support/net/local_address.zig
// does for the tests. Connecting a UDP socket asks the kernel which source
// address a routed connection would use and sends no packet.
fn routableLocalIpv4(out: *[64]u8) !usize {
    const remote = try std.net.Address.parseIp4("1.1.1.1", 9);
    const socket = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    defer std.posix.close(socket);
    try std.posix.connect(socket, &remote.any, remote.getOsSockLen());

    var storage: std.posix.sockaddr.storage = undefined;
    var storage_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(socket, @ptrCast(&storage), &storage_len);
    if (storage.family != std.posix.AF.INET)
        return error.NoRoutableLocalIpv4;

    const socket_address: *align(4) const std.posix.sockaddr = @ptrCast(&storage);
    const address = std.net.Address.initPosix(socket_address);
    const bytes = transport.ipv4Bytes(address);
    const host = try std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    return host.len;
}

const ProcessMemory = struct {
    rss_kib: u64 = 0,
    peak_rss_kib: u64 = 0,
};

fn readProcessMemory() ProcessMemory {
    var file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return .{};
    defer file.close();
    var buffer: [64 * 1024]u8 = undefined;
    const len = file.readAll(&buffer) catch return .{};
    return .{
        .rss_kib = procStatusKb(buffer[0..len], "VmRSS:") catch 0,
        .peak_rss_kib = procStatusKb(buffer[0..len], "VmHWM:") catch 0,
    };
}

fn procStatusKb(status: []const u8, key: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key))
            continue;
        const rest = std.mem.trim(u8, line[key.len..], &std.ascii.whitespace);
        const end = std.mem.indexOfAny(u8, rest, &std.ascii.whitespace) orelse rest.len;
        return std.fmt.parseUnsigned(u64, rest[0..end], 10);
    }
    return error.ProcStatusKeyMissing;
}

fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default: usize) !usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default,
        else => return err,
    };
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10);
}

fn printJsonSample(scenario: Scenario, iteration: usize, requests: usize, sample: Sample) void {
    std.debug.print(
        "{{\"bench\":\"egress_http1\",\"scenario\":\"{s}\",\"iteration\":{d},\"requests\":{d},\"elapsed_ns\":{d},\"ttfb_ns\":{d},\"rss_kib\":{d},\"peak_rss_kib\":{d},\"accepted_connections\":{d},\"ns_per_request\":{d:.3}}}\n",
        .{
            @tagName(scenario),
            iteration,
            requests,
            sample.elapsed_ns,
            sample.ttfb_ns,
            sample.rss_kib,
            sample.peak_rss_kib,
            sample.accepted_connections,
            @as(f64, @floatFromInt(sample.elapsed_ns)) / @as(f64, @floatFromInt(requests)),
        },
    );
}

fn printSummary(scenario: Scenario, requests: usize, sorted_elapsed_samples: []const u64, sorted_ttfb_samples: []const u64) void {
    const p50_ns = percentile(sorted_elapsed_samples, 50);
    const p95_ns = percentile(sorted_elapsed_samples, 95);
    const ttfb_p50_ns = percentile(sorted_ttfb_samples, 50);
    const ttfb_p95_ns = percentile(sorted_ttfb_samples, 95);
    std.debug.print(
        "egress_http1_summary scenario={s} samples={d} requests={d} p50_ns_per_request={d:.3} p95_ns_per_request={d:.3} ttfb_p50_ns={d} ttfb_p95_ns={d}\n",
        .{
            @tagName(scenario),
            sorted_elapsed_samples.len,
            requests,
            @as(f64, @floatFromInt(p50_ns)) / @as(f64, @floatFromInt(requests)),
            @as(f64, @floatFromInt(p95_ns)) / @as(f64, @floatFromInt(requests)),
            ttfb_p50_ns,
            ttfb_p95_ns,
        },
    );
}

fn percentile(sorted_samples: []const u64, percentile_value: usize) u64 {
    const rank = @max(@as(usize, 1), (sorted_samples.len * percentile_value + 99) / 100);
    return sorted_samples[@min(rank, sorted_samples.len) - 1];
}
