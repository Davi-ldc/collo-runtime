//! Measures the egress TLS data paths in this process, against local
//! BoringSSL test origins that run on their own threads. Full and
//! session-resumed handshakes are timed on the fd path, where BoringSSL reads
//! and writes the socket itself. Every other scenario runs over the BIO path
//! driven by io_uring: a handshake alone that negotiates HTTP/2, and HTTP/2
//! uploads, downloads, small frames and a 100-stream multiplex through the h2
//! pool and its data driver. Each BIO sample starts a fresh origin, pool and
//! drivers. A transfer sample primes its connection with one untimed request
//! and fails unless every stream reused that connection and the body bytes
//! received total the stream count times the response size. Like every
//! egress bench it builds ReleaseFast without JSC.

const std = @import("std");
const bench_metadata = @import("metadata.zig");
const pool_mod = @import("collo_egress_pool");

const data_io = pool_mod.data_io;
const readiness = pool_mod.readiness;
const transport = pool_mod.transport;

const default_iterations: usize = 20;
const default_warmup_iterations: usize = 3;

const tls_shim = @import("collo_test_tls_shim");
const TestH2Origin = tls_shim.TestH2Origin;
const collo_bench_h2_origin_start = tls_shim.collo_bench_h2_origin_start;
const collo_test_h2_origin_stop = tls_shim.collo_test_h2_origin_stop;
const collo_test_h2_origin_last_error = tls_shim.collo_test_h2_origin_last_error;

const TestTlsResumptionOrigin = tls_shim.TestTlsResumptionOrigin;
const collo_test_tls_resumption_origin_start = tls_shim.collo_test_tls_resumption_origin_start;
const collo_test_tls_resumption_origin_stop = tls_shim.collo_test_tls_resumption_origin_stop;

const Path = enum {
    bio_iouring,
    fd_blocking,

    fn name(self: Path) []const u8 {
        return @tagName(self);
    }
};

const ResumptionMode = enum {
    full,
    resumed,
};

const Scenario = struct {
    name: []const u8,
    request_body_bytes: usize = 0,
    response_body_bytes: usize = 0,
    streams: u32 = 1,
    handshake_only: bool = false,
};

const Sample = struct {
    elapsed_ns: u64,
    ttfb_ns: u64,
    rss_kib: u64,
    peak_rss_kib: u64,
};

const CompletionStats = struct {
    first_head_ns: ?u64 = null,
};

const scenarios = [_]Scenario{
    .{ .name = "handshake", .handshake_only = true },
    .{ .name = "upload_16k", .request_body_bytes = 16 * 1024 },
    .{ .name = "upload_256k", .request_body_bytes = 256 * 1024 },
    .{ .name = "download_16k", .response_body_bytes = 16 * 1024 },
    .{ .name = "download_256k", .response_body_bytes = 256 * 1024 },
    .{ .name = "small_frame_h2", .response_body_bytes = 1, .streams = 32 },
    .{ .name = "multiplex_100_small_h2", .response_body_bytes = 2, .streams = 100 },
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    try bench_metadata.print(allocator, "egress_tls");
    const iterations = try envUsize(allocator, "COLLO_BENCH_EGRESS_ITERATIONS", default_iterations);
    const warmup_iterations = try envUsize(allocator, "COLLO_BENCH_EGRESS_WARMUP", default_warmup_iterations);

    try runResumptionScenario(allocator, .full, iterations, warmup_iterations);
    try runResumptionScenario(allocator, .resumed, iterations, warmup_iterations);

    const path: Path = .bio_iouring;
    for (scenarios) |scenario| {
        const elapsed_samples = try allocator.alloc(u64, iterations);
        defer allocator.free(elapsed_samples);
        const ttfb_samples = try allocator.alloc(u64, iterations);
        defer allocator.free(ttfb_samples);

        var warmup: usize = 0;
        while (warmup < warmup_iterations) : (warmup += 1)
            _ = try runSample(allocator, scenario);

        for (elapsed_samples, ttfb_samples, 0..) |*elapsed, *ttfb, iteration| {
            const sample = try runSample(allocator, scenario);
            elapsed.* = sample.elapsed_ns;
            ttfb.* = sample.ttfb_ns;
            printJsonSample(path, scenario, iteration + 1, sample);
        }
        std.mem.sort(u64, elapsed_samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, ttfb_samples, {}, std.sort.asc(u64));
        printSummary(path, scenario, elapsed_samples, ttfb_samples);
    }
}

/// TLS handshake latency on the fd path, full or session-resumed. One origin,
/// and so one server SSL_CTX whose tickets stay valid, serves every connect.
/// The first connect and the warmup connects are not measured. Under
/// `resumed` the first one fills the session cache and every later connect
/// must resume; under `full` none may.
fn runResumptionScenario(
    allocator: std.mem.Allocator,
    mode: ResumptionMode,
    iterations: usize,
    warmup_iterations: usize,
) !void {
    const tls = transport.tls;
    const scenario = Scenario{
        .name = switch (mode) {
            .full => "tls_handshake_full",
            .resumed => "tls_handshake_resumed",
        },
        .handshake_only = true,
    };
    const total_connects = 1 + warmup_iterations + iterations;

    var origin: ?*TestTlsResumptionOrigin = null;
    var port: u16 = 0;
    if (collo_test_tls_resumption_origin_start(@intCast(total_connects), &origin, &port) != 0)
        return error.EgressBenchOriginStartFailed;
    defer collo_test_tls_resumption_origin_stop(origin.?);

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const address = try std.net.Address.parseIp(host, port);
    const cell: [16]u8 = [_]u8{7} ** 16;
    // A ticket is only reusable under the offer that produced it, so the key
    // and the handshake must read the same offer.
    const alpn_offer: tls.AlpnOffer = .http_1_1;
    var key_buffer: [tls.max_session_key_bytes]u8 = undefined;
    const session_key: ?[]const u8 = switch (mode) {
        // No cache interaction: the cost of a cold handshake alone.
        .full => null,
        // One cell id as both the security and the policy cell, plus the ALPN
        // offer every connect uses, keeps the key stable across the scenario,
        // which is what lets the measured handshakes resume.
        .resumed => tls.buildSessionKey(&key_buffer, cell, cell, alpn_offer, host, port),
    };

    const elapsed_samples = try allocator.alloc(u64, iterations);
    defer allocator.free(elapsed_samples);

    var connect_index: usize = 0;
    var sample_index: usize = 0;
    while (connect_index < total_connects) : (connect_index += 1) {
        const measured = connect_index >= 1 + warmup_iterations;
        const stream = try std.net.tcpConnectToAddress(address);
        const start_ns = try monotonicNowNs();
        const connection = try tls.Connection.create(allocator, stream, host, true, alpn_offer, session_key);
        const handshake_ns = (try monotonicNowNs()) - start_ns;
        defer connection.deinit();
        // The origin writes one byte post-handshake; reading it pulls the
        // NewSessionTickets in so the next connect can resume.
        var ready: [1]u8 = undefined;
        switch (try connection.readStep(&ready)) {
            .ready => {},
            else => return error.EgressBenchOriginReadFailed,
        }
        const reused = connection.sessionReused();
        // The very first connect is always full; with a key every later one
        // must resume, without one none may.
        if (connect_index != 0 and reused != (mode == .resumed))
            return error.EgressBenchUnexpectedResumptionState;

        if (measured) {
            elapsed_samples[sample_index] = handshake_ns;
            sample_index += 1;
            printJsonSample(.fd_blocking, scenario, sample_index, sampleWithMemory(handshake_ns, handshake_ns));
        }
    }

    std.mem.sort(u64, elapsed_samples, {}, std.sort.asc(u64));
    printSummary(.fd_blocking, scenario, elapsed_samples, elapsed_samples);
}

fn runSample(allocator: std.mem.Allocator, scenario: Scenario) !Sample {
    var origin: ?*TestH2Origin = null;
    var port: u16 = 0;
    if (collo_bench_h2_origin_start(
        if (scenario.handshake_only) 1 else scenario.streams + 1,
        scenario.response_body_bytes,
        &origin,
        &port,
    ) != 0)
        return error.EgressBenchOriginStartFailed;
    defer collo_test_h2_origin_stop(origin.?);

    const body = try allocator.alloc(u8, scenario.request_body_bytes);
    defer allocator.free(body);
    @memset(body, 'p');

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const url = try std.fmt.allocPrint(allocator, "https://{s}:{d}/bench", .{ host, port });
    defer allocator.free(url);
    const config = transport.Config{
        .allow_private_networks = true,
        .insecure_tls = true,
        .socket_timeout_ms = 15_000,
        .max_response_body_bytes = @max(scenario.response_body_bytes, 1),
        .http2_max_active_streams = @max(scenario.streams, 1),
        .http2_max_outgoing_buffer_bytes = @max(scenario.request_body_bytes + 64 * 1024, 1024 * 1024),
        .tls_ciphertext_buffer_bytes = @max(scenario.request_body_bytes + 64 * 1024, 1024 * 1024),
    };

    var plan = try transport.prepareRequest(allocator, url, "POST", &.{}, config);
    defer plan.deinit();
    var readiness_driver = readiness.Driver.init(allocator);
    defer readiness_driver.deinit();
    var dns_cache = transport.DnsCache.init(allocator, .{});
    defer dns_cache.deinit();
    // Pool entries own BIO connections that the data driver's deinit drain
    // still touches; LIFO defers must run the driver's deinit before the
    // pool frees them.
    var client_pool = pool_mod.Pool.init(allocator, .{ .max_entries = 1 });
    defer client_pool.deinit();
    var data_driver = try data_io.Driver.init(allocator);
    defer data_driver.deinit();

    if (scenario.handshake_only) {
        const start_ns = try monotonicNowNs();
        var wire = try connectBioH2(allocator, &plan, config, &dns_cache, &readiness_driver, &data_driver);
        defer wire.deinit();
        const end_ns = try monotonicNowNs();
        return sampleWithMemory(end_ns - start_ns, end_ns - start_ns);
    }

    var wire = try connectBioH2(allocator, &plan, config, &dns_cache, &readiness_driver, &data_driver);
    var wire_owned = true;
    defer if (wire_owned)
        wire.deinit();

    const prime_request = pool_mod.BatchRequest{
        .allocator = allocator,
        .url = url,
        .method = "POST",
        .body = "",
        .headers = &.{},
        .config = config,
    };
    const entry = switch (try client_pool.adoptConnection(prime_request, wire)) {
        .pending => |stream| stream.entry,
        else => return error.EgressBenchExpectedPendingStream,
    };
    wire_owned = false;
    _ = try completeStreams(entry, &client_pool, &data_driver, 1, 0, null);

    const request = pool_mod.BatchRequest{
        .allocator = allocator,
        .url = url,
        .method = "POST",
        .body = body,
        .headers = &.{},
        .config = config,
    };
    const start_ns = try monotonicNowNs();
    switch (try client_pool.startRequest(request)) {
        .pending => |stream| if (stream.entry != entry) return error.EgressBenchDidNotReuseConnection,
        else => return error.EgressBenchExpectedPendingStream,
    }
    var stream_index: u32 = 1;
    while (stream_index < scenario.streams) : (stream_index += 1) {
        switch (try client_pool.startRequest(request)) {
            .pending => |stream| if (stream.entry != entry) return error.EgressBenchDidNotReuseConnection,
            else => return error.EgressBenchExpectedPendingStream,
        }
    }
    const completed = try completeStreams(
        entry,
        &client_pool,
        &data_driver,
        scenario.streams,
        scenario.response_body_bytes,
        start_ns,
    );
    const elapsed_ns = (try monotonicNowNs()) - start_ns;
    return sampleWithMemory(elapsed_ns, completed.first_head_ns orelse elapsed_ns);
}

fn connectBioH2(
    allocator: std.mem.Allocator,
    plan: *const transport.RequestPlan,
    config: transport.Config,
    dns_cache: *transport.DnsCache,
    readiness_driver: *readiness.Driver,
    data_driver: *data_io.Driver,
) !transport.HttpConnection {
    return switch (try pool_mod.Entry.connectBio(allocator, plan, config, dns_cache, readiness_driver, data_driver)) {
        .h2 => |connected| connected,
        .h1 => |connected| {
            var rejected = connected;
            rejected.deinit();
            return error.EgressBenchExpectedH2Negotiation;
        },
    };
}

fn completeStreams(
    entry: *pool_mod.Entry,
    client_pool: *pool_mod.Pool,
    data_driver: *data_io.Driver,
    stream_count: u32,
    expected_response_body_bytes: usize,
    start_ns: ?u64,
) !CompletionStats {
    var completed: u32 = 0;
    var received_body_bytes: usize = 0;
    var stats = CompletionStats{};
    while (completed < stream_count) {
        while (completed < stream_count) {
            var event = client_pool.readEntryEvent(entry) catch |err| switch (err) {
                error.Http2WouldBlock => break,
                else => return err,
            };
            defer event.deinit();
            switch (event) {
                .head => {
                    if (stats.first_head_ns == null) {
                        if (start_ns) |start|
                            stats.first_head_ns = (try monotonicNowNs()) - start;
                    }
                },
                .body_chunk => |body| {
                    received_body_bytes += body.bytes.len;
                    var maybe_end = try client_pool.ackReceivedData(entry, body.stream_id, body.flow_credit, body.update_stream_window);
                    if (maybe_end) |*end_event| {
                        defer end_event.deinit();
                        switch (end_event.*) {
                            .end => completed += 1,
                            .failure => |failure| return failure.err,
                            else => {},
                        }
                    }
                },
                .end => completed += 1,
                // An interim (1xx) block would land between the request and the
                // head this scenario times. The bench origin serves one final
                // response and nothing else, so a progress event means the
                // origin changed and these samples no longer compare with the
                // ones before it.
                .progress => return error.EgressBenchUnexpectedInterimResponse,
                .failure => |failure| return failure.err,
            }
        }
        if (completed == stream_count)
            break;
        try waitForEntry(entry, data_driver);
    }
    const expected_total_body_bytes = @as(usize, stream_count) * expected_response_body_bytes;
    if (received_body_bytes != expected_total_body_bytes)
        return error.EgressBenchUnexpectedResponseBody;
    return stats;
}

fn waitForEntry(
    entry: *pool_mod.Entry,
    data_driver: *data_io.Driver,
) !void {
    var context: u8 = 0;
    switch (try data_driver.wait(&.{.{
        .context = &context,
        .connection = entry.bioTls() orelse return error.EgressBenchExpectedBioTls,
        .deadline_mono_ns = try data_io.deadlineAfterMs(15_000),
        .want_read = true,
        .want_write = entry.wantsOutgoingWrite(),
    }}, null)) {
        .ready => |ready| if (ready.writable and entry.hasOutgoing()) try entry.flushOutgoing(),
        .failed => |failure| return failure.err,
        .expired => return error.EgressBenchTimeout,
        .wake, .tick => {},
    }
}

fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sampleWithMemory(elapsed_ns: u64, ttfb_ns: u64) Sample {
    const memory = readProcessMemory();
    return .{
        .elapsed_ns = elapsed_ns,
        .ttfb_ns = ttfb_ns,
        .rss_kib = memory.rss_kib,
        .peak_rss_kib = memory.peak_rss_kib,
    };
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

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default: usize) !usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default,
        else => return err,
    };
    defer allocator.free(raw);
    return std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10);
}

const route_probe_ipv4 = "1.1.1.1";
const route_probe_port: u16 = 9;

// The egress policy always denies loopback, so the bench reaches its local
// origins through the machine's default-route source address, as
// runtime/tests/support/net/local_address.zig does for the tests.
fn routableLocalIpv4(out: *[64]u8) ![]const u8 {
    const address = try defaultRouteSourceAddress();
    (transport.EgressPolicy{ .allow_private_networks = true }).validateResolvedAddress(address) catch {
        std.debug.print("egress_tls: default-route source address is not egress-permitted\n", .{});
        return error.BenchNoRoutableLocalAddress;
    };
    const bytes = transport.ipv4Bytes(address);
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
}

fn defaultRouteSourceAddress() !std.net.Address {
    const remote = try std.net.Address.parseIp4(route_probe_ipv4, route_probe_port);
    const socket = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    defer std.posix.close(socket);

    // UDP connect does not send a packet; it only asks the kernel which source
    // address would be used for a normal routed connection.
    try std.posix.connect(socket, &remote.any, remote.getOsSockLen());

    var storage: std.posix.sockaddr.storage = undefined;
    var storage_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(socket, @ptrCast(&storage), &storage_len);
    if (storage.family != std.posix.AF.INET)
        return error.BenchNoRoutableLocalAddress;
    const socket_address: *align(4) const std.posix.sockaddr = @ptrCast(&storage);
    return std.net.Address.initPosix(socket_address);
}

fn printJsonSample(path: Path, scenario: Scenario, iteration: usize, sample: Sample) void {
    const operations = if (scenario.handshake_only) @as(u32, 1) else scenario.streams;
    std.debug.print(
        "{{\"bench\":\"egress_tls\",\"path\":\"{s}\",\"scenario\":\"{s}\",\"iteration\":{d},\"streams\":{d},\"request_body_bytes\":{d},\"response_body_bytes\":{d},\"elapsed_ns\":{d},\"ttfb_ns\":{d},\"rss_kib\":{d},\"peak_rss_kib\":{d},\"ns_per_operation\":{d:.3}}}\n",
        .{
            path.name(),
            scenario.name,
            iteration,
            operations,
            scenario.request_body_bytes,
            scenario.response_body_bytes,
            sample.elapsed_ns,
            sample.ttfb_ns,
            sample.rss_kib,
            sample.peak_rss_kib,
            @as(f64, @floatFromInt(sample.elapsed_ns)) / @as(f64, @floatFromInt(operations)),
        },
    );
}

fn printSummary(path: Path, scenario: Scenario, sorted_elapsed_samples: []const u64, sorted_ttfb_samples: []const u64) void {
    const operations = if (scenario.handshake_only) @as(u32, 1) else scenario.streams;
    const p50_ns = percentile(sorted_elapsed_samples, 50);
    const p95_ns = percentile(sorted_elapsed_samples, 95);
    const ttfb_p50_ns = percentile(sorted_ttfb_samples, 50);
    const ttfb_p95_ns = percentile(sorted_ttfb_samples, 95);
    std.debug.print(
        "egress_tls_summary path={s} scenario={s} samples={d} streams={d} p50_ns_per_operation={d:.3} p95_ns_per_operation={d:.3} ttfb_p50_ns={d} ttfb_p95_ns={d}\n",
        .{
            path.name(),
            scenario.name,
            sorted_elapsed_samples.len,
            operations,
            @as(f64, @floatFromInt(p50_ns)) / @as(f64, @floatFromInt(operations)),
            @as(f64, @floatFromInt(p95_ns)) / @as(f64, @floatFromInt(operations)),
            ttfb_p50_ns,
            ttfb_p95_ns,
        },
    );
}

fn percentile(sorted_samples: []const u64, percentile_value: usize) u64 {
    const rank = @max(@as(usize, 1), (sorted_samples.len * percentile_value + 99) / 100);
    return sorted_samples[@min(rank, sorted_samples.len) - 1];
}
