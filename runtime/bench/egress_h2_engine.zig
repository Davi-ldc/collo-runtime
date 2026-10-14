//! Measures the HTTP/2 throughput and stream latency of the egress engine's
//! owner thread across a matrix of engines, origins, streams and response
//! sizes. The engine is the one each gateway shard runs, and every origin is
//! a local C++ test origin on its own thread that accepts exactly one
//! connection. Like every egress bench it builds ReleaseFast without JSC.
//!
//! Each engine stands for one gateway shard and gets its own driver thread,
//! its own `egress.Engine` and its own origins, since an origin cannot serve
//! a second connection. The driver runs a closed loop over a fixed number of
//! in-flight slots bound to origins up front. It releases fetch-body credits
//! on every wake, because the engine opens HTTP/2 flow-control windows only
//! as credits come back, and it sleeps on an eventfd that the engine's wake
//! callback writes.
//!
//! By default one untimed request per origin pays for its dial before the
//! timed window, which then measures established connections. With
//! COLLO_BENCH_H2_ENGINE_DIAL_IN_WINDOW=1 the window starts with no
//! connection, so each origin's first stream waits on the owner's own DNS,
//! TCP connect and TLS handshake while the other origins' streams run: many
//! origins with few requests each make the handshake-heavy mix whose stream
//! latency decides whether handshakes stay on the owner thread.

const std = @import("std");
const bench_common = @import("common.zig");
const bench_metadata = @import("metadata.zig");
const local_origin = @import("local_origin.zig");
const egress = @import("collo_egress_client");

const egress_engine = egress.engine;
const task_model = egress.task;
const body_credit = egress.core.body_credit;
const ResponseQueue = egress.core.ResponseQueue;

const tls_shim = @import("collo_test_tls_shim");
const TestH2Origin = tls_shim.TestH2Origin;
const collo_bench_h2_origin_start = tls_shim.collo_bench_h2_origin_start;
const collo_test_h2_origin_stop = tls_shim.collo_test_h2_origin_stop;
const collo_test_h2_origin_last_error = tls_shim.collo_test_h2_origin_last_error;

const default_engines = [_]usize{ 1, 2, 4 };
const default_origins = [_]usize{ 1, 4, 16 };
const default_streams = [_]usize{ 8, 32 };
const default_response_bytes = [_]usize{ 1024, 16384, 262144 };
const default_inflight: usize = 0;
const default_requests: usize = 2000;
const default_iterations: usize = 5;
const default_warmup_iterations: usize = 1;

/// One group of COLLO_BENCH_H2_ENGINE_MIX, which describes each engine's
/// origins as groups with their own response size and share of the measured
/// requests. "2048x2:70,32768x1:25,262144x1:5" is two origins serving 2 KiB
/// bodies that together receive 70% of the requests, one at 32 KiB receiving
/// 25% and one at 256 KiB receiving 5%. Skewed weights over one size model a
/// hot origin ("4096x1:80,4096x7:20"). A MIX replaces the ORIGINS and
/// RESPONSE_BYTES lists; the ENGINES and STREAMS lists still apply.
const MixGroup = struct {
    response_bytes: usize,
    origins: usize,
    weight: usize,
};

const max_mix_classes: usize = 8;

/// Every origin holds one pooled connection for the whole cell, so the
/// origins per engine must fit in the engine's HTTP/2 pool. The engine builds
/// that pool with the default `Config`, so its limit is the default
/// `Config.max_entries` in egress/client/transport/h2/pool.zig; past it the
/// pool evicts an idle entry or fails the request with
/// `error.Http2PoolExhausted`. This bound stays below that limit.
const max_origins_per_engine: usize = 32;
/// The payload size of the DATA frames the test origin sends (`cellConfig`).
const origin_data_frame_bytes: usize = 16 * 1024;
const stall_timeout_ns: u64 = 30 * std.time.ns_per_s;
const h2_max_window: u64 = (1 << 31) - 1;

const Cell = struct {
    engines: usize,
    origins: usize,
    streams: usize,
    response_bytes: usize,
    /// Resolved in-flight slot target per engine (0 env value => origins*streams).
    inflight: usize,
    /// Measured requests per engine.
    requests: usize,
    /// Each origin's dial runs inside the timed window
    /// (COLLO_BENCH_H2_ENGINE_DIAL_IN_WINDOW=1).
    dial_in_window: bool,
    /// Per-engine origin population (always populated; a uniform run is a
    /// single group). One class index per group for TTFB reporting.
    mix: []const MixGroup,
    /// Human-readable mix spec for log lines ("uniform" for single-class runs).
    mix_desc: []const u8,
    /// Largest response size across the mix; drives windows and credit budgets.
    max_response_bytes: usize,
};

const Sample = struct {
    elapsed_ns: u64,
    req_per_s: f64,
    mb_per_s: f64,
    ttfb_p50_ns: u64,
    ttfb_p99_ns: u64,
    /// Per-size-class TTFB percentiles (indexes follow Cell.mix; only the
    /// first Cell.mix.len entries are meaningful, and only when mix.len > 1).
    ttfb_class_p50_ns: [max_mix_classes]u64,
    ttfb_class_p99_ns: [max_mix_classes]u64,
    rss_kib: u64,
    peak_rss_kib: u64,
};

/// Where the test origins, which listen on every address, are dialed: the
/// default route's source address (`local_origin.zig`), since every grant
/// refuses loopback.
var origin_address: [4]u8 = undefined;
var origin_host_buffer: [15]u8 = undefined;
var origin_host: []const u8 = &.{};

comptime {
    // One engine's origins fit one policy.
    std.debug.assert(max_origins_per_engine <= local_origin.origins_max);
}

pub fn main() !void {
    // Several engine threads allocate at once, and DebugAllocator's single
    // lock would show up as contention the engine does not have;
    // smp_allocator keeps a freelist per thread.
    const allocator = std.heap.smp_allocator;
    try bench_metadata.print(allocator, "egress_h2_engine");
    origin_address = try local_origin.routableLocalIpv4();
    origin_host = local_origin.formatIpv4(origin_address, &origin_host_buffer);

    const engines_list = try bench_common.parseCommaSeparatedUsizeList(allocator, "COLLO_BENCH_H2_ENGINE_ENGINES", &default_engines);
    defer allocator.free(engines_list);
    const origins_list = try bench_common.parseCommaSeparatedUsizeList(allocator, "COLLO_BENCH_H2_ENGINE_ORIGINS", &default_origins);
    defer allocator.free(origins_list);
    const streams_list = try bench_common.parseCommaSeparatedUsizeList(allocator, "COLLO_BENCH_H2_ENGINE_STREAMS", &default_streams);
    defer allocator.free(streams_list);
    const response_bytes_list = try bench_common.parseCommaSeparatedUsizeList(allocator, "COLLO_BENCH_H2_ENGINE_RESPONSE_BYTES", &default_response_bytes);
    defer allocator.free(response_bytes_list);
    const inflight = try envUsize(allocator, "COLLO_BENCH_H2_ENGINE_INFLIGHT", default_inflight);
    const requests = try envUsize(allocator, "COLLO_BENCH_H2_ENGINE_REQUESTS", default_requests);
    const iterations = try envUsize(allocator, "COLLO_BENCH_H2_ENGINE_ITERATIONS", default_iterations);
    const warmup_iterations = try envUsize(allocator, "COLLO_BENCH_H2_ENGINE_WARMUP", default_warmup_iterations);
    const dial_in_window = (try envUsize(allocator, "COLLO_BENCH_H2_ENGINE_DIAL_IN_WINDOW", 0)) != 0;
    const mix_env = try parseMixEnv(allocator, "COLLO_BENCH_H2_ENGINE_MIX");
    if (requests == 0 or iterations == 0)
        return error.InvalidBenchConfig;
    for (origins_list) |origin_count| {
        if (origin_count > max_origins_per_engine) {
            std.debug.print(
                "egress_h2_engine: origins={d} exceeds the engine HTTP/2 pool limit of {d}\n",
                .{ origin_count, max_origins_per_engine },
            );
            return error.InvalidBenchConfig;
        }
    }
    for ([_][]const usize{ engines_list, origins_list, streams_list }) |list| {
        for (list) |value| {
            if (value == 0) {
                std.debug.print(
                    "egress_h2_engine: engines/origins/streams matrix entries must be nonzero\n",
                    .{},
                );
                return error.InvalidBenchConfig;
            }
        }
    }

    // Resolve the per-cell origin populations: either the explicit MIX (one
    // population shared by every engines/streams combination) or one
    // single-class population per origins x response-size matrix entry.
    var populations = std.ArrayList(MixEntry).empty;
    defer populations.deinit(allocator);
    if (mix_env) |entry| {
        try populations.append(allocator, entry);
    } else {
        for (origins_list) |origin_count| {
            for (response_bytes_list) |response_bytes| {
                const groups = try allocator.alloc(MixGroup, 1);
                groups[0] = .{ .response_bytes = response_bytes, .origins = origin_count, .weight = 1 };
                try populations.append(allocator, .{ .groups = groups, .desc = "uniform" });
            }
        }
    }

    const total_cells = engines_list.len * populations.items.len * streams_list.len;
    std.debug.print(
        "egress_h2_engine: {d} cells ({d} engines x {d} populations x {d} streams), {d} requests/engine, {d} warmup + {d} measured iterations, dial_in_window={}\n",
        .{
            total_cells,
            engines_list.len,
            populations.items.len,
            streams_list.len,
            requests,
            warmup_iterations,
            iterations,
            dial_in_window,
        },
    );

    for (engines_list) |engine_count| {
        for (populations.items) |population| {
            for (streams_list) |stream_count| {
                const totals = mixTotals(population.groups);
                const cell = Cell{
                    .engines = engine_count,
                    .origins = totals.origins,
                    .streams = stream_count,
                    .response_bytes = totals.mean_bytes,
                    .inflight = if (inflight == 0) totals.origins * stream_count else inflight,
                    .requests = requests,
                    .dial_in_window = dial_in_window,
                    .mix = population.groups,
                    .mix_desc = population.desc,
                    .max_response_bytes = totals.max_bytes,
                };
                try runCell(allocator, cell, iterations, warmup_iterations);
            }
        }
    }
}

const MixEntry = struct {
    groups: []const MixGroup,
    desc: []const u8,
};

/// Parses "BYTESxORIGINS:WEIGHT[,BYTESxORIGINS:WEIGHT...]". Weights are
/// relative shares of the measured requests (per engine); origins are spawned
/// per engine exactly like the uniform path.
fn parseMixEnv(allocator: std.mem.Allocator, name: []const u8) !?MixEntry {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => |other| return other,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0)
        return null;

    var groups = std.ArrayList(MixGroup).empty;
    errdefer groups.deinit(allocator);
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    var total_origins: usize = 0;
    while (parts.next()) |part| {
        const spec = std.mem.trim(u8, part, " \t");
        const x_index = std.mem.indexOfScalar(u8, spec, 'x') orelse return error.InvalidMixSpec;
        const colon_index = std.mem.indexOfScalarPos(u8, spec, x_index + 1, ':') orelse return error.InvalidMixSpec;
        const group = MixGroup{
            .response_bytes = try std.fmt.parseUnsigned(usize, spec[0..x_index], 10),
            .origins = try std.fmt.parseUnsigned(usize, spec[x_index + 1 .. colon_index], 10),
            .weight = try std.fmt.parseUnsigned(usize, spec[colon_index + 1 ..], 10),
        };
        if (group.origins == 0 or group.weight == 0 or group.response_bytes == 0)
            return error.InvalidMixSpec;
        total_origins += group.origins;
        try groups.append(allocator, group);
    }
    if (groups.items.len == 0 or groups.items.len > max_mix_classes)
        return error.InvalidMixSpec;
    if (total_origins == 0 or total_origins > max_origins_per_engine)
        return error.InvalidMixSpec;
    return .{
        .groups = try groups.toOwnedSlice(allocator),
        .desc = try allocator.dupe(u8, trimmed),
    };
}

fn mixTotals(groups: []const MixGroup) struct { origins: usize, max_bytes: usize, mean_bytes: usize } {
    var origins: usize = 0;
    var max_bytes: usize = 0;
    var weight_total: usize = 0;
    var weighted_bytes: u128 = 0;
    for (groups) |group| {
        origins += group.origins;
        max_bytes = @max(max_bytes, group.response_bytes);
        weight_total += group.weight;
        weighted_bytes += @as(u128, group.weight) * @as(u128, group.response_bytes);
    }
    return .{
        .origins = origins,
        .max_bytes = max_bytes,
        .mean_bytes = @intCast(weighted_bytes / @max(weight_total, 1)),
    };
}

fn runCell(allocator: std.mem.Allocator, cell: Cell, iterations: usize, warmup_iterations: usize) !void {
    const config = cellConfig(cell);

    const elapsed_samples = try allocator.alloc(u64, iterations);
    defer allocator.free(elapsed_samples);
    const req_per_s_samples = try allocator.alloc(f64, iterations);
    defer allocator.free(req_per_s_samples);
    const mb_per_s_samples = try allocator.alloc(f64, iterations);
    defer allocator.free(mb_per_s_samples);
    const ttfb_p50_samples = try allocator.alloc(u64, iterations);
    defer allocator.free(ttfb_p50_samples);
    const ttfb_p99_samples = try allocator.alloc(u64, iterations);
    defer allocator.free(ttfb_p99_samples);
    const class_count = cell.mix.len;
    const class_p50_samples = try allocator.alloc(u64, class_count * iterations);
    defer allocator.free(class_p50_samples);
    const class_p99_samples = try allocator.alloc(u64, class_count * iterations);
    defer allocator.free(class_p99_samples);

    var warmup: usize = 0;
    while (warmup < warmup_iterations) : (warmup += 1)
        _ = try runSample(allocator, cell, config);

    var iteration: usize = 0;
    while (iteration < iterations) : (iteration += 1) {
        const sample = try runSample(allocator, cell, config);
        elapsed_samples[iteration] = sample.elapsed_ns;
        req_per_s_samples[iteration] = sample.req_per_s;
        mb_per_s_samples[iteration] = sample.mb_per_s;
        ttfb_p50_samples[iteration] = sample.ttfb_p50_ns;
        ttfb_p99_samples[iteration] = sample.ttfb_p99_ns;
        for (0..class_count) |class| {
            class_p50_samples[class * iterations + iteration] = sample.ttfb_class_p50_ns[class];
            class_p99_samples[class * iterations + iteration] = sample.ttfb_class_p99_ns[class];
        }
        printJsonSample(cell, iteration + 1, sample);
    }

    std.mem.sort(u64, elapsed_samples, {}, std.sort.asc(u64));
    std.mem.sort(f64, req_per_s_samples, {}, std.sort.asc(f64));
    std.mem.sort(f64, mb_per_s_samples, {}, std.sort.asc(f64));
    std.mem.sort(u64, ttfb_p50_samples, {}, std.sort.asc(u64));
    std.mem.sort(u64, ttfb_p99_samples, {}, std.sort.asc(u64));
    std.debug.print(
        "egress_h2_engine_summary engines={d} origins={d} streams={d} response_body_bytes={d} inflight={d} requests={d} dial_in_window={} samples={d} elapsed_p50_ns={d} req_per_s_p50={d:.1} req_per_s_best={d:.1} mb_per_s_p50={d:.2} ttfb_p50_ns={d} ttfb_p99_ns={d} mix={s}\n",
        .{
            cell.engines,
            cell.origins,
            cell.streams,
            cell.response_bytes,
            cell.inflight,
            cell.requests,
            cell.dial_in_window,
            iterations,
            bench_common.percentileNearestRank(u64, elapsed_samples, 50),
            bench_common.percentileNearestRank(f64, req_per_s_samples, 50),
            req_per_s_samples[req_per_s_samples.len - 1],
            bench_common.percentileNearestRank(f64, mb_per_s_samples, 50),
            bench_common.percentileNearestRank(u64, ttfb_p50_samples, 50),
            bench_common.percentileNearestRank(u64, ttfb_p99_samples, 50),
            cell.mix_desc,
        },
    );
    if (class_count > 1) {
        for (cell.mix, 0..) |group, class| {
            const p50_slice = class_p50_samples[class * iterations .. (class + 1) * iterations];
            const p99_slice = class_p99_samples[class * iterations .. (class + 1) * iterations];
            std.mem.sort(u64, p50_slice, {}, std.sort.asc(u64));
            std.mem.sort(u64, p99_slice, {}, std.sort.asc(u64));
            std.debug.print(
                "egress_h2_engine_class_summary engines={d} streams={d} inflight={d} mix={s} class={d} bytes={d} class_origins={d} weight={d} ttfb_p50_ns={d} ttfb_p99_ns={d}\n",
                .{
                    cell.engines,
                    cell.streams,
                    cell.inflight,
                    cell.mix_desc,
                    class,
                    group.response_bytes,
                    group.origins,
                    group.weight,
                    bench_common.percentileNearestRank(u64, p50_slice, 50),
                    bench_common.percentileNearestRank(u64, p99_slice, 50),
                },
            );
        }
    }
}

/// One transport config per cell, so every request to an origin carries the
/// same isolation ids and matches that origin's single pooled connection,
/// whose HTTP/2 limits come from the first request's config. The test origin ignores client flow control and sends `origin_data_frame_bytes`
/// DATA frames, so the receive windows must cover everything it can send: the
/// stream window covers the largest response, and the connection window
/// covers every stream's window, both capped at the HTTP/2 maximum.
fn cellConfig(cell: Cell) egress.Config {
    const window_target: u64 = @min(@max(@as(u64, cell.max_response_bytes), 64 * 1024), h2_max_window);
    const conn_target: u64 = @min(@as(u64, cell.streams) * window_target, h2_max_window);
    const stream_window: u32 = @intCast(window_target);
    const conn_window: u32 = @intCast(@max(conn_target, window_target));
    return .{
        // Each engine starts its own origins on ports the kernel picks, so
        // `runEngine` replaces this with the policy that names them before
        // any task runs.
        .network = egress.network.deny_all,
        .insecure_tls = true,
        .enable_http2 = true,
        .socket_timeout_ms = 30_000,
        .max_response_body_bytes = @max(cell.max_response_bytes, 1),
        .max_encoded_response_bytes = @max(cell.max_response_bytes, 64 * 1024),
        .max_pending_decoded_body_bytes = @max(cell.max_response_bytes, 64 * 1024),
        .http2_max_active_streams = @max(cell.streams, 1),
        .http2_stream_receive_window = stream_window,
        .http2_conn_receive_window = conn_window,
        // `Limits.normalized` in egress/client/transport/h2/codec/client.zig
        // clamps the advertised windows to these credit budgets, so the
        // budgets grow with the windows.
        .http2_max_pending_body_credit_per_stream = @intCast(window_target),
        .http2_max_pending_body_credit_per_connection = conn_window,
    };
}

const OriginState = struct {
    handle: ?*TestH2Origin = null,
    port: u16 = 0,
    url: []u8 = &.{},
    /// Measured requests assigned to this origin (sets expected_stream_count).
    assigned: usize = 0,
    /// Measured requests not yet submitted.
    remaining: usize = 0,
    /// Response body size this origin serves (from its mix group).
    response_bytes: usize = 0,
    /// Mix class index (position of the origin's group in Cell.mix).
    class: u8 = 0,
};

const Slot = struct {
    origin_index: usize,
    task: ?*task_model.Task = null,
    submit_ns: u64 = 0,
    ttfb_ns: ?u64 = null,
};

const EngineContext = struct {
    allocator: std.mem.Allocator,
    cell: Cell,
    config: egress.Config,
    engine_index: usize,
    go_event: *std.Thread.ResetEvent,
    ready_sem: *std.Thread.Semaphore,
    ttfb_ns: []u64,
    /// Mix class of each recorded TTFB (parallel to ttfb_ns).
    ttfb_class: []u8,
    next_task_id: u64,
    wake_fd: std.posix.fd_t = -1,
    ttfb_count: usize = 0,
    finished_ns: u64 = 0,
    credited_bytes: u64 = 0,
    /// Exact body bytes this engine should receive over the timed window
    /// (sum over origins of assigned * response_bytes).
    expected_bytes: u64 = 0,
    ready_posted: bool = false,
    err: ?anyerror = null,
    fail_detail: [768]u8 = undefined,
    fail_detail_len: usize = 0,
};

fn runSample(allocator: std.mem.Allocator, cell: Cell, config: egress.Config) !Sample {
    var go_event = std.Thread.ResetEvent{};
    var ready_sem = std.Thread.Semaphore{};

    const contexts = try allocator.alloc(EngineContext, cell.engines);
    defer allocator.free(contexts);
    const merged_ttfb = try allocator.alloc(u64, cell.engines * cell.requests);
    defer allocator.free(merged_ttfb);
    const merged_class = try allocator.alloc(u8, cell.engines * cell.requests);
    defer allocator.free(merged_class);
    for (contexts, 0..) |*context, index| {
        context.* = .{
            .allocator = allocator,
            .cell = cell,
            .config = config,
            .engine_index = index,
            .go_event = &go_event,
            .ready_sem = &ready_sem,
            .ttfb_ns = merged_ttfb[index * cell.requests .. (index + 1) * cell.requests],
            .ttfb_class = merged_class[index * cell.requests .. (index + 1) * cell.requests],
            .next_task_id = @as(u64, @intCast(index + 1)) << 32,
        };
    }

    const threads = try allocator.alloc(std.Thread, cell.engines);
    defer allocator.free(threads);
    var spawned: usize = 0;
    errdefer {
        go_event.set();
        for (threads[0..spawned]) |thread|
            thread.join();
    }
    while (spawned < cell.engines) : (spawned += 1)
        threads[spawned] = try std.Thread.spawn(.{}, engineThreadMain, .{&contexts[spawned]});

    var readies: usize = 0;
    while (readies < cell.engines) : (readies += 1)
        ready_sem.wait();

    const start_ns = try monotonicNowNs();
    go_event.set();
    for (threads) |thread|
        thread.join();
    spawned = 0;

    for (contexts) |*context| {
        if (context.err) |err| {
            if (context.fail_detail_len != 0)
                std.debug.print(
                    "egress_h2_engine engine[{d}] failed: {s}\n",
                    .{ context.engine_index, context.fail_detail[0..context.fail_detail_len] },
                );
            return err;
        }
    }

    var finished_max: u64 = start_ns;
    var ttfb_total: usize = 0;
    var credited_bytes: u64 = 0;
    var expected_bytes: u64 = 0;
    for (contexts) |*context| {
        finished_max = @max(finished_max, context.finished_ns);
        ttfb_total += context.ttfb_count;
        credited_bytes += context.credited_bytes;
        expected_bytes += context.expected_bytes;
    }
    if (ttfb_total != merged_ttfb.len)
        return error.BenchSampleIncomplete;
    if (credited_bytes != expected_bytes)
        std.debug.print(
            "egress_h2_engine: credited body bytes {d} != expected {d} (some chunks carried non-h2_data credits)\n",
            .{ credited_bytes, expected_bytes },
        );

    const elapsed_ns = @max(finished_max - start_ns, 1);

    // Per-class TTFB percentiles must be computed before the merged sort
    // destroys the value<->class pairing.
    var ttfb_class_p50_ns: [max_mix_classes]u64 = @splat(0);
    var ttfb_class_p99_ns: [max_mix_classes]u64 = @splat(0);
    if (cell.mix.len > 1) {
        const scratch = try allocator.alloc(u64, merged_ttfb.len);
        defer allocator.free(scratch);
        for (0..cell.mix.len) |class| {
            var count: usize = 0;
            for (merged_ttfb, merged_class) |value, value_class| {
                if (value_class == class) {
                    scratch[count] = value;
                    count += 1;
                }
            }
            if (count == 0)
                continue;
            std.mem.sort(u64, scratch[0..count], {}, std.sort.asc(u64));
            ttfb_class_p50_ns[class] = bench_common.percentileNearestRank(u64, scratch[0..count], 50);
            ttfb_class_p99_ns[class] = bench_common.percentileNearestRank(u64, scratch[0..count], 99);
        }
    }

    std.mem.sort(u64, merged_ttfb, {}, std.sort.asc(u64));
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const memory = readProcessMemory();
    return .{
        .elapsed_ns = elapsed_ns,
        .req_per_s = @as(f64, @floatFromInt(merged_ttfb.len)) / seconds,
        .mb_per_s = @as(f64, @floatFromInt(expected_bytes)) / (1024.0 * 1024.0) / seconds,
        .ttfb_p50_ns = bench_common.percentileNearestRank(u64, merged_ttfb, 50),
        .ttfb_p99_ns = bench_common.percentileNearestRank(u64, merged_ttfb, 99),
        .ttfb_class_p50_ns = ttfb_class_p50_ns,
        .ttfb_class_p99_ns = ttfb_class_p99_ns,
        .rss_kib = memory.rss_kib,
        .peak_rss_kib = memory.peak_rss_kib,
    };
}

fn engineThreadMain(context: *EngineContext) void {
    runEngine(context) catch |err| {
        if (context.err == null)
            context.err = err;
    };
    if (!context.ready_posted) {
        context.ready_posted = true;
        context.ready_sem.post();
    }
}

fn runEngine(context: *EngineContext) !void {
    const allocator = context.allocator;
    const cell = context.cell;
    const origin_count = cell.origins;

    context.wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(context.wake_fd);

    const origins = try allocator.alloc(OriginState, origin_count);
    defer allocator.free(origins);
    for (origins) |*origin|
        origin.* = .{};
    defer for (origins) |*origin| {
        if (origin.handle) |handle|
            collo_test_h2_origin_stop(handle);
        if (origin.url.len != 0)
            allocator.free(origin.url);
    };

    // The measured requests are split deterministically: in proportion to
    // group weight across the mix, with the leftovers dealt round-robin over
    // the groups, then evenly across each group's origins. An origin serves
    // its streams on its one connection, then closes it without GOAWAY, and
    // answers its first stream with an empty body: the priming request's, or
    // with the dial in the window, the first measured one's. A uniform run is
    // a single group, so every origin gets the base share and the first ones
    // one more.
    var weight_total: usize = 0;
    for (cell.mix) |group|
        weight_total += group.weight;
    var group_requests: [max_mix_classes]usize = @splat(0);
    var assigned_total: usize = 0;
    for (cell.mix, 0..) |group, group_index| {
        group_requests[group_index] = cell.requests * group.weight / weight_total;
        assigned_total += group_requests[group_index];
    }
    var leftover = cell.requests - assigned_total;
    var leftover_group: usize = 0;
    while (leftover > 0) : (leftover -= 1) {
        group_requests[leftover_group] += 1;
        leftover_group = (leftover_group + 1) % cell.mix.len;
    }

    var origin_cursor: usize = 0;
    for (cell.mix, 0..) |group, group_index| {
        const group_base = group_requests[group_index] / group.origins;
        const group_rem = group_requests[group_index] % group.origins;
        for (0..group.origins) |member| {
            const origin = &origins[origin_cursor];
            origin_cursor += 1;
            origin.assigned = group_base + @intFromBool(member < group_rem);
            origin.remaining = origin.assigned;
            origin.response_bytes = group.response_bytes;
            origin.class = @intCast(group_index);
            const full_responses = if (cell.dial_in_window) origin.assigned -| 1 else origin.assigned;
            context.expected_bytes += @as(u64, @intCast(full_responses)) * @as(u64, @intCast(group.response_bytes));
            const priming_streams: usize = if (cell.dial_in_window) 0 else 1;
            var handle: ?*TestH2Origin = null;
            var port: u16 = 0;
            if (collo_bench_h2_origin_start(
                @intCast(priming_streams + origin.assigned),
                origin.response_bytes,
                &handle,
                &port,
            ) != 0)
                return error.BenchOriginStartFailed;
            origin.handle = handle.?;
            origin.port = port;
            origin.url = try std.fmt.allocPrint(allocator, "https://{s}:{d}/bench", .{ origin_host, port });
        }
    }

    // The engine below, and every task it runs, ends before this returns,
    // so the grant outlives every hop that reads it.
    var origin_ports: [max_origins_per_engine]u16 = undefined;
    for (origins, 0..) |origin, index|
        origin_ports[index] = origin.port;
    var grant: local_origin.LocalGrant = undefined;
    try grant.init(origin_address, origin_ports[0..origin_count]);
    context.config.network = grant.policy();

    // Binding each slot to one origin up front keeps an origin's concurrency
    // within the HTTP/2 stream limit, so the engine never opens a second
    // connection, which the test origin would never accept. Quotas follow
    // each origin's share of the traffic, so in-flight concurrency matches
    // the mix weights, and every origin with work gets at least one slot so
    // the closed loop can always finish.
    const slot_quota = try allocator.alloc(usize, origin_count);
    defer allocator.free(slot_quota);
    var total_slots: usize = 0;
    for (slot_quota, origins) |*quota, origin| {
        if (origin.assigned == 0) {
            quota.* = 0;
            continue;
        }
        const share = @max(cell.inflight * origin.assigned / cell.requests, 1);
        quota.* = @min(@min(share, cell.streams), origin.assigned);
        total_slots += quota.*;
    }
    // Top up flooring losses so the total in-flight target stays comparable
    // across mixes; stop once every origin hits its stream/assigned cap.
    var spare = cell.inflight -| total_slots;
    while (spare > 0) {
        var granted = false;
        for (slot_quota, origins) |*quota, origin| {
            if (spare == 0)
                break;
            if (quota.* == 0 or quota.* >= @min(cell.streams, origin.assigned))
                continue;
            quota.* += 1;
            total_slots += 1;
            spare -= 1;
            granted = true;
        }
        if (!granted)
            break;
    }

    const slots = try allocator.alloc(Slot, @max(total_slots, origin_count));
    defer allocator.free(slots);
    for (slots) |*slot|
        slot.* = .{ .origin_index = 0 };

    // Each slot runs one fetch at a time, and the priming phase one per
    // origin, including an origin no measured request drew.
    var engine = try egress_engine.Engine.init(allocator, slots.len);
    defer {
        // Queued body credits go back first, then `engine.stop` settles every
        // pending task and drops the engine's references. Only then are the
        // queues final: the second release drains them (a stopped engine
        // takes no credit), the bench drops its own task references, and
        // the engine goes last.
        for (slots) |*slot| {
            if (slot.task) |task|
                releaseTaskCredits(context, &engine, task);
        }
        engine.stop();
        for (slots) |*slot| {
            if (slot.task) |task| {
                releaseTaskCredits(context, &engine, task);
                destroyTask(task);
                slot.task = null;
            }
        }
        engine.deinit();
    }

    try engine.start(context, wakeFromEngine);

    // Unless the dial belongs in the window, one untimed request per origin
    // pays for the DNS lookup, the TCP connect, the TLS handshake and the
    // HTTP/2 session setup. The origin answers it with an empty body, so the
    // timed window below measures only established connections.
    if (!cell.dial_in_window) {
        for (slots[0..origin_count], 0..) |*slot, index| {
            slot.* = .{ .origin_index = index };
            try submitSlot(context, &engine, slot, origins);
        }
        try driveLoop(context, &engine, slots[0..origin_count], origins, origin_count, .prime);
    }

    context.ready_posted = true;
    context.ready_sem.post();
    context.go_event.wait();

    var slot_index: usize = 0;
    for (slot_quota, 0..) |quota, origin_index| {
        var allocated: usize = 0;
        while (allocated < quota) : (allocated += 1) {
            slots[slot_index] = .{ .origin_index = origin_index };
            slot_index += 1;
        }
    }
    for (slots[total_slots..]) |*slot|
        slot.* = .{ .origin_index = 0 };
    for (slots[0..total_slots]) |*slot| {
        const origin = &origins[slot.origin_index];
        if (origin.remaining == 0)
            continue;
        origin.remaining -= 1;
        try submitSlot(context, &engine, slot, origins);
    }
    try driveLoop(context, &engine, slots[0..total_slots], origins, cell.requests, .timed);
    context.finished_ns = try monotonicNowNs();

    for (origins) |*origin| {
        const last_error = std.mem.span(collo_test_h2_origin_last_error(origin.handle.?));
        if (last_error.len != 0)
            return failEngine(context, "origin reported error", last_error, origin.url);
    }
}

const Phase = enum { prime, timed };

fn driveLoop(
    context: *EngineContext,
    engine: *egress_engine.Engine,
    slots: []Slot,
    origins: []OriginState,
    target_completions: usize,
    phase: Phase,
) !void {
    var completed: usize = 0;
    var stall_deadline_ns = (try monotonicNowNs()) + stall_timeout_ns;
    while (completed < target_completions) {
        const progress = try scanSlots(context, engine, slots, origins, &completed, phase);
        if (progress) {
            stall_deadline_ns = (try monotonicNowNs()) + stall_timeout_ns;
            continue;
        }
        if (completed >= target_completions)
            break;
        waitWakeReadable(context.wake_fd, stall_deadline_ns) catch |err| switch (err) {
            error.BenchStalled => {
                reportStall(context, engine, slots, origins, completed, target_completions);
                return error.BenchStalled;
            },
            else => return err,
        };
        drainEventFd(context.wake_fd);
    }
}

fn scanSlots(
    context: *EngineContext,
    engine: *egress_engine.Engine,
    slots: []Slot,
    origins: []OriginState,
    completed: *usize,
    phase: Phase,
) !bool {
    var progress = false;
    const now_ns = try monotonicNowNs();
    for (slots) |*slot| {
        const task = slot.task orelse continue;

        // Credits go back on every scan because the engine sends HTTP/2
        // window updates only for DATA the consumer has acknowledged.
        releaseTaskCredits(context, engine, task);

        var failure_message: ?[]const u8 = null;
        task.mutex.lock();
        const done = task.done;
        if (done) {
            if (task.result) |result| switch (result) {
                .success => |success| {
                    if (success.status != 200)
                        failure_message = "unexpected response status";
                },
                .failure => |failure| failure_message = failure.message,
            } else failure_message = "task done without result";
        }
        if (failure_message) |message|
            copyFailDetail(context, message);
        task.mutex.unlock();
        if (!done)
            continue;
        if (failure_message != null) {
            const origin = &origins[slot.origin_index];
            const last_error = if (origin.handle) |handle|
                std.mem.span(collo_test_h2_origin_last_error(handle))
            else
                "";
            return failEngine(context, context.fail_detail[0..context.fail_detail_len], last_error, origin.url);
        }

        if (slot.ttfb_ns == null)
            slot.ttfb_ns = now_ns -| slot.submit_ns;

        switch (bodyState(task.response_body)) {
            .open => continue,
            .failed => {
                const origin = &origins[slot.origin_index];
                const last_error = if (origin.handle) |handle|
                    std.mem.span(collo_test_h2_origin_last_error(handle))
                else
                    "";
                var message_buffer: [256]u8 = undefined;
                task.response_body.mutex.lock();
                const body_error = task.response_body.error_message orelse "";
                const message_len = @min(body_error.len, message_buffer.len);
                std.mem.copyForwards(u8, message_buffer[0..message_len], body_error[0..message_len]);
                task.response_body.mutex.unlock();
                var detail_buffer: [320]u8 = undefined;
                const detail = std.fmt.bufPrint(
                    &detail_buffer,
                    "response body failed: {s}",
                    .{message_buffer[0..message_len]},
                ) catch "response body failed";
                return failEngine(context, detail, last_error, origin.url);
            },
            .complete => {},
        }

        // The producer is finished, so this drains everything that is still
        // queued and nothing new can arrive afterwards.
        releaseTaskCredits(context, engine, task);
        destroyTask(task);
        slot.task = null;
        completed.* += 1;
        progress = true;

        if (phase == .timed) {
            context.ttfb_ns[context.ttfb_count] = slot.ttfb_ns.?;
            context.ttfb_class[context.ttfb_count] = origins[slot.origin_index].class;
            context.ttfb_count += 1;
            const origin = &origins[slot.origin_index];
            if (origin.remaining > 0) {
                origin.remaining -= 1;
                try submitSlot(context, engine, slot, origins);
            }
        }
    }
    return progress;
}

fn submitSlot(
    context: *EngineContext,
    engine: *egress_engine.Engine,
    slot: *Slot,
    origins: []OriginState,
) !void {
    const task = try createTask(context, origins[slot.origin_index].url);
    errdefer destroyTask(task);
    slot.ttfb_ns = null;
    slot.submit_ns = try monotonicNowNs();
    try engine.submit(.{ .task = task, .config = context.config });
    slot.task = task;
}

fn createTask(context: *EngineContext, url: []const u8) !*task_model.Task {
    const allocator = context.allocator;
    context.next_task_id += 1;
    const id = context.next_task_id;
    const identity = egress.core.FetchBodyIdentity{
        .request_id = id,
        .request_generation = 1,
        .fetch_id = id,
        .body_id = id,
    };
    const queue = try allocator.create(ResponseQueue);
    var queue_owned = true;
    errdefer if (queue_owned) queue.release(allocator);
    queue.* = ResponseQueue.init(identity, null);
    const task = try allocator.create(task_model.Task);
    errdefer allocator.destroy(task);
    task.* = try task_model.Task.init(allocator, id, url, "GET", "", &.{}, 0, queue);
    queue_owned = false;
    return task;
}

/// Drops the bench's reference. The engine may still hold its own for a
/// moment after it woke the bench on the body's end, and the last holder
/// frees the task.
fn destroyTask(task: *task_model.Task) void {
    task.release();
}

const CreditRelease = struct {
    context: *EngineContext,
    engine: *egress_engine.Engine,
};

fn releaseCreditToEngine(release: *CreditRelease, credit: body_credit.Handle) void {
    switch (credit) {
        .h2_data => |data| release.context.credited_bytes += data.encoded_bytes,
        else => {},
    }
    release.engine.releaseFetchBodyCredit(credit);
}

fn releaseTaskCredits(context: *EngineContext, engine: *egress_engine.Engine, task: *task_model.Task) void {
    var release = CreditRelease{ .context = context, .engine = engine };
    task.response_body.releaseQueued(context.allocator, &release, releaseCreditToEngine);
}

fn bodyState(queue: *ResponseQueue) egress.core.response_queue.State {
    queue.mutex.lock();
    defer queue.mutex.unlock();
    return queue.state;
}

fn wakeFromEngine(ctx: ?*anyopaque, event: egress_engine.WakeEvent) void {
    _ = event;
    const context: *EngineContext = @ptrCast(@alignCast(ctx orelse return));
    var one: u64 = 1;
    _ = std.posix.write(context.wake_fd, std.mem.asBytes(&one)) catch {};
}

fn drainEventFd(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch {};
}

/// Waits for an engine wake or a bounded rescan tick. The engine always wakes
/// on response headers, but a queue wakes on its completion only while its
/// consumer armed it, which this bench does not do, so the last completion
/// of a phase may bring no wake at all. Returning on the tick lets driveLoop
/// rescan, and a real stall still reaches the caller's deadline and fails
/// with `error.BenchStalled`.
fn waitWakeReadable(fd: std.posix.fd_t, deadline_ns: u64) !void {
    const rescan_tick_ms: u64 = 10;
    const now_ns = try monotonicNowNs();
    if (now_ns >= deadline_ns)
        return error.BenchStalled;
    const remaining_ms: u64 = @min((deadline_ns - now_ns) / std.time.ns_per_ms + 1, rescan_tick_ms);
    var pollfds = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, @intCast(remaining_ms));
    if (ready == 0)
        return;
    if (pollfds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0)
        return error.BenchWakeFdFailed;
}

fn failEngine(
    context: *EngineContext,
    message: []const u8,
    origin_last_error: []const u8,
    origin_url: []const u8,
) error{BenchTaskFailed} {
    var buffer: [768]u8 = undefined;
    var len: usize = 0;
    appendBounded(&buffer, &len, message);
    appendBounded(&buffer, &len, " (origin ");
    appendBounded(&buffer, &len, origin_url);
    appendBounded(&buffer, &len, ", origin last_error: \"");
    appendBounded(&buffer, &len, origin_last_error);
    appendBounded(&buffer, &len, "\")");
    copyFailDetail(context, buffer[0..len]);
    return error.BenchTaskFailed;
}

fn appendBounded(buffer: []u8, len: *usize, text: []const u8) void {
    const take = @min(buffer.len - len.*, text.len);
    std.mem.copyForwards(u8, buffer[len.*..][0..take], text[0..take]);
    len.* += take;
}

fn copyFailDetail(context: *EngineContext, message: []const u8) void {
    const len = @min(message.len, context.fail_detail.len);
    std.mem.copyForwards(u8, context.fail_detail[0..len], message[0..len]);
    context.fail_detail_len = len;
}

fn reportStall(
    context: *EngineContext,
    engine: *egress_engine.Engine,
    slots: []Slot,
    origins: []OriginState,
    completed: usize,
    target_completions: usize,
) void {
    std.debug.print(
        "egress_h2_engine engine[{d}] stalled at {d}/{d} completions\n",
        .{ context.engine_index, completed, target_completions },
    );
    // A frozen owner leaves work queued: submissions or cancels linked, or
    // credit sources listed. An idle owner that lost a wake or a credit has
    // nothing queued and waits for an event that never comes. Each in-flight
    // slot's body state then shows which stream the missing wake or credit
    // belongs to.
    {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        engine.mutex.lock();
        const submissions_queued = engine.submitted_head != null;
        const cancels_queued = engine.canceled_head != null;
        var sources_listed: usize = 0;
        for (engine.credit_sources.slots.items) |slot| {
            if (slot.queued) sources_listed += 1;
        }
        const sources_live = engine.credit_sources.live;
        engine.mutex.unlock();
        std.debug.print(
            "DIAG stall engine[{d}]: submissions queued={} cancels queued={} credit sources listed {d} of {d} live\n",
            .{ context.engine_index, submissions_queued, cancels_queued, sources_listed, sources_live },
        );
        for (slots, 0..) |*slot, index| {
            const task = slot.task orelse continue;
            task.mutex.lock();
            const done = task.done;
            task.mutex.unlock();
            std.debug.print(
                "DIAG stall slot[{d}]: origin={d} done={} body_state={s} queued_bytes={d}\n",
                .{
                    index,
                    slot.origin_index,
                    done,
                    @tagName(bodyState(task.response_body)),
                    task.response_body.queuedBytes(),
                },
            );
        }
    }
    for (origins) |*origin| {
        const handle = origin.handle orelse continue;
        const last_error = std.mem.span(collo_test_h2_origin_last_error(handle));
        if (last_error.len != 0)
            std.debug.print(
                "egress_h2_engine engine[{d}] origin {s} last_error: {s}\n",
                .{ context.engine_index, origin.url, last_error },
            );
    }
}

fn printJsonSample(cell: Cell, iteration: usize, sample: Sample) void {
    std.debug.print(
        "{{\"bench\":\"egress_h2_engine\",\"mix\":\"{s}\",\"engines\":{d},\"origins\":{d},\"streams\":{d},\"response_body_bytes\":{d},\"inflight\":{d},\"requests\":{d},\"dial_in_window\":{},\"iteration\":{d},\"elapsed_ns\":{d},\"req_per_s\":{d:.1},\"mb_per_s\":{d:.2},\"ttfb_p50_ns\":{d},\"ttfb_p99_ns\":{d},\"rss_kib\":{d},\"peak_rss_kib\":{d}}}\n",
        .{
            cell.mix_desc,
            cell.engines,
            cell.origins,
            cell.streams,
            cell.response_bytes,
            cell.inflight,
            cell.requests,
            cell.dial_in_window,
            iteration,
            sample.elapsed_ns,
            sample.req_per_s,
            sample.mb_per_s,
            sample.ttfb_p50_ns,
            sample.ttfb_p99_ns,
            sample.rss_kib,
            sample.peak_rss_kib,
        },
    );
    if (cell.mix.len > 1) {
        for (cell.mix, 0..) |group, class| {
            std.debug.print(
                "egress_h2_engine_class engines={d} iteration={d} class={d} bytes={d} ttfb_p50_ns={d} ttfb_p99_ns={d}\n",
                .{
                    cell.engines,
                    iteration,
                    class,
                    group.response_bytes,
                    sample.ttfb_class_p50_ns[class],
                    sample.ttfb_class_p99_ns[class],
                },
            );
        }
    }
}

fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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
