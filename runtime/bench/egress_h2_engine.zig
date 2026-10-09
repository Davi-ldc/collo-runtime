//! Measures the HTTP/2 throughput of the egress engine's owner thread
//! (`h2Main`) across a matrix of engines, h2 connectors, origins, streams and
//! response sizes. The engine is the one each gateway shard runs, and every
//! origin is a local C++ test origin on its own thread that accepts exactly
//! one connection. Like every egress bench it builds ReleaseFast without JSC.
//!
//! Each engine stands for one gateway shard and gets its own driver thread,
//! its own `egress.Engine` and its own origins, since an origin cannot serve
//! a second connection. The driver runs a closed loop over a fixed number of
//! in-flight slots bound to origins up front. It releases fetch-body credits
//! on every wake, because the engine opens HTTP/2 flow-control windows only
//! as credits come back, and it sleeps on an eventfd that the engine's wake
//! callback writes.

const std = @import("std");
const bench_common = @import("common.zig");
const bench_metadata = @import("metadata.zig");
const bindings = @import("collo_bindings");
const egress = @import("collo_egress_client");

const egress_engine = egress.engine;
const fetch_body = egress.fetch_body;
const task_model = egress.task;
const body_credit = egress.core.body_credit;

const tls_shim = @import("collo_test_tls_shim");
const TestH2Origin = tls_shim.TestH2Origin;
const collo_bench_h2_origin_start = tls_shim.collo_bench_h2_origin_start;
const collo_test_h2_origin_stop = tls_shim.collo_test_h2_origin_stop;
const collo_test_h2_origin_last_error = tls_shim.collo_test_h2_origin_last_error;

const default_engines = [_]usize{ 1, 2, 4 };
const default_connectors = [_]usize{ 1, 2 };
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
/// RESPONSE_BYTES lists; the ENGINES, CONNECTORS and STREAMS lists still
/// apply.
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
/// The test origin sends DATA in frames of this payload size; used only to
/// budget the engine command queue for eager credit releases.
const origin_data_frame_bytes: usize = 16 * 1024;
const stall_timeout_ns: u64 = 30 * std.time.ns_per_s;
const h2_max_window: u64 = (1 << 31) - 1;

const Cell = struct {
    engines: usize,
    connectors: usize,
    origins: usize,
    streams: usize,
    response_bytes: usize,
    /// Resolved in-flight slot target per engine (0 env value => origins*streams).
    inflight: usize,
    /// Measured requests per engine.
    requests: usize,
    /// True, as the gateway sets it, unless COLLO_BENCH_H2_ENGINE_PREREGISTER=0
    /// turns it off to debug a kernel whose sealed, restricted io_uring data
    /// path misbehaves.
    pre_register_recv_buffers: bool,
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
    /// Aggregate h2 owner busy% across engines (sum busy / sum busy+wait).
    h2_busy_pct: f64,
    /// Worst single-engine busy%, which shows when one owner thread saturates.
    h2_busy_pct_max: f64,
    h2_busy_ns: u64,
    h2_wait_ns: u64,
    h2_process_ns: u64,
    h2_maintain_ns: u64,
    h2_handle_ns: u64,
    h2_iterations: u64,
    h2_batch_messages: u64,
    h2_queue_depth_max: u64,
    h2_watch_list_len_max: u64,
};

/// One engine's H2Stats over its timed window. Counters are end minus start.
/// Maxima are the end values: every sample starts a fresh engine, and the
/// priming requests put at most one request per origin in flight.
const H2Window = struct {
    busy_ns: u64 = 0,
    wait_ns: u64 = 0,
    process_ns: u64 = 0,
    maintain_ns: u64 = 0,
    handle_ns: u64 = 0,
    iterations: u64 = 0,
    batch_messages: u64 = 0,
    queue_depth_max: u64 = 0,
    watch_list_len_max: u64 = 0,

    fn busyPct(self: H2Window) f64 {
        const total = self.busy_ns + self.wait_ns;
        if (total == 0)
            return 0;
        return 100.0 * @as(f64, @floatFromInt(self.busy_ns)) / @as(f64, @floatFromInt(total));
    }
};

/// The egress policy always denies loopback, so that a fetch cannot reach
/// services on the gateway's own machine. The bench therefore reaches the
/// test origins, which listen on INADDR_ANY, through the machine's
/// default-route source address, as runtime/tests/support/net/local_address.zig
/// does for the tests.
var origin_host_buffer: [64]u8 = undefined;
var origin_host: []const u8 = &.{};

pub fn main() !void {
    // Several engine threads allocate at once, and DebugAllocator's single
    // lock would show up as contention the engine does not have;
    // smp_allocator keeps a freelist per thread.
    const allocator = std.heap.smp_allocator;
    try bench_metadata.print(allocator, "egress_h2_engine");
    origin_host = try routableLocalIpv4(&origin_host_buffer);

    const engines_list = try bench_common.parseCommaSeparatedUsizeList(allocator, "COLLO_BENCH_H2_ENGINE_ENGINES", &default_engines);
    defer allocator.free(engines_list);
    const connectors_list = try bench_common.parseCommaSeparatedUsizeList(allocator, "COLLO_BENCH_H2_ENGINE_CONNECTORS", &default_connectors);
    defer allocator.free(connectors_list);
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
    const pre_register = (try envUsize(allocator, "COLLO_BENCH_H2_ENGINE_PREREGISTER", 1)) != 0;
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
    for ([_][]const usize{ engines_list, connectors_list, origins_list, streams_list }) |list| {
        for (list) |value| {
            if (value == 0) {
                std.debug.print(
                    "egress_h2_engine: engines/connectors/origins/streams matrix entries must be nonzero\n",
                    .{},
                );
                return error.InvalidBenchConfig;
            }
        }
    }

    // Resolve the per-cell origin populations: either the explicit MIX (one
    // population shared by every engines/connectors/streams combination) or
    // one single-class population per origins x response-size matrix entry.
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

    const total_cells = engines_list.len * connectors_list.len * populations.items.len * streams_list.len;
    std.debug.print(
        "egress_h2_engine: {d} cells ({d} engines x {d} connectors x {d} populations x {d} streams), {d} requests/engine, {d} warmup + {d} measured iterations\n",
        .{
            total_cells,
            engines_list.len,
            connectors_list.len,
            populations.items.len,
            streams_list.len,
            requests,
            warmup_iterations,
            iterations,
        },
    );

    for (engines_list) |engine_count| {
        for (connectors_list) |connector_count| {
            for (populations.items) |population| {
                for (streams_list) |stream_count| {
                    const totals = mixTotals(population.groups);
                    const cell = Cell{
                        .engines = engine_count,
                        .connectors = connector_count,
                        .origins = totals.origins,
                        .streams = stream_count,
                        .response_bytes = totals.mean_bytes,
                        .inflight = if (inflight == 0) totals.origins * stream_count else inflight,
                        .requests = requests,
                        .pre_register_recv_buffers = pre_register,
                        .mix = population.groups,
                        .mix_desc = population.desc,
                        .max_response_bytes = totals.max_bytes,
                    };
                    try runCell(allocator, cell, iterations, warmup_iterations);
                }
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
    const h2_busy_pct_samples = try allocator.alloc(f64, iterations);
    defer allocator.free(h2_busy_pct_samples);
    const h2_busy_pct_max_samples = try allocator.alloc(f64, iterations);
    defer allocator.free(h2_busy_pct_max_samples);
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
        h2_busy_pct_samples[iteration] = sample.h2_busy_pct;
        h2_busy_pct_max_samples[iteration] = sample.h2_busy_pct_max;
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
    std.mem.sort(f64, h2_busy_pct_samples, {}, std.sort.asc(f64));
    std.mem.sort(f64, h2_busy_pct_max_samples, {}, std.sort.asc(f64));
    std.debug.print(
        "egress_h2_engine_summary engines={d} h2_connectors={d} origins={d} streams={d} response_body_bytes={d} inflight={d} requests={d} samples={d} elapsed_p50_ns={d} req_per_s_p50={d:.1} req_per_s_best={d:.1} mb_per_s_p50={d:.2} ttfb_p50_ns={d} ttfb_p99_ns={d} h2_busy_pct_p50={d:.1} h2_busy_pct_max={d:.1} mix={s}\n",
        .{
            cell.engines,
            cell.connectors,
            cell.origins,
            cell.streams,
            cell.response_bytes,
            cell.inflight,
            cell.requests,
            iterations,
            bench_common.percentileNearestRank(u64, elapsed_samples, 50),
            bench_common.percentileNearestRank(f64, req_per_s_samples, 50),
            req_per_s_samples[req_per_s_samples.len - 1],
            bench_common.percentileNearestRank(f64, mb_per_s_samples, 50),
            bench_common.percentileNearestRank(u64, ttfb_p50_samples, 50),
            bench_common.percentileNearestRank(u64, ttfb_p99_samples, 50),
            bench_common.percentileNearestRank(f64, h2_busy_pct_samples, 50),
            h2_busy_pct_max_samples[h2_busy_pct_max_samples.len - 1],
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

/// One transport config per cell, because the pool key holds the config's
/// HTTP/2 limits and buffer sizes next to the origin: with one config, every
/// request to an origin matches that origin's single pooled connection. The
/// test origin ignores client flow control and sends `origin_data_frame_bytes`
/// DATA frames, so the receive windows must cover everything it can send: the
/// stream window covers the largest response, and the connection window
/// covers every stream's window, both capped at the HTTP/2 maximum.
fn cellConfig(cell: Cell) egress.Config {
    const window_target: u64 = @min(@max(@as(u64, cell.max_response_bytes), 64 * 1024), h2_max_window);
    const conn_target: u64 = @min(@as(u64, cell.streams) * window_target, h2_max_window);
    const stream_window: u32 = @intCast(window_target);
    const conn_window: u32 = @intCast(@max(conn_target, window_target));
    return .{
        .allow_private_networks = true,
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
    h2: H2Window = .{},
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
    var h2_busy_ns: u64 = 0;
    var h2_wait_ns: u64 = 0;
    var h2_process_ns: u64 = 0;
    var h2_maintain_ns: u64 = 0;
    var h2_handle_ns: u64 = 0;
    var h2_busy_pct_max: f64 = 0;
    var h2_iterations: u64 = 0;
    var h2_batch_messages: u64 = 0;
    var h2_queue_depth_max: u64 = 0;
    var h2_watch_list_len_max: u64 = 0;
    for (contexts) |*context| {
        finished_max = @max(finished_max, context.finished_ns);
        ttfb_total += context.ttfb_count;
        credited_bytes += context.credited_bytes;
        expected_bytes += context.expected_bytes;
        h2_busy_ns += context.h2.busy_ns;
        h2_wait_ns += context.h2.wait_ns;
        h2_process_ns += context.h2.process_ns;
        h2_maintain_ns += context.h2.maintain_ns;
        h2_handle_ns += context.h2.handle_ns;
        h2_busy_pct_max = @max(h2_busy_pct_max, context.h2.busyPct());
        h2_iterations += context.h2.iterations;
        h2_batch_messages += context.h2.batch_messages;
        h2_queue_depth_max = @max(h2_queue_depth_max, context.h2.queue_depth_max);
        h2_watch_list_len_max = @max(h2_watch_list_len_max, context.h2.watch_list_len_max);
    }
    const h2_total_ns = h2_busy_ns + h2_wait_ns;
    const h2_busy_pct: f64 = if (h2_total_ns == 0)
        0
    else
        100.0 * @as(f64, @floatFromInt(h2_busy_ns)) / @as(f64, @floatFromInt(h2_total_ns));
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
        .h2_busy_pct = h2_busy_pct,
        .h2_busy_pct_max = h2_busy_pct_max,
        .h2_busy_ns = h2_busy_ns,
        .h2_wait_ns = h2_wait_ns,
        .h2_process_ns = h2_process_ns,
        .h2_maintain_ns = h2_maintain_ns,
        .h2_handle_ns = h2_handle_ns,
        .h2_iterations = h2_iterations,
        .h2_batch_messages = h2_batch_messages,
        .h2_queue_depth_max = h2_queue_depth_max,
        .h2_watch_list_len_max = h2_watch_list_len_max,
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
    // exactly one priming response plus its assigned ones on its one
    // connection, then closes it without GOAWAY. A uniform run is a single
    // group, so every origin gets the base share and the first ones one more.
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
            context.expected_bytes += @as(u64, @intCast(origin.assigned)) * @as(u64, @intCast(group.response_bytes));
            var handle: ?*TestH2Origin = null;
            var port: u16 = 0;
            if (collo_bench_h2_origin_start(
                @intCast(1 + origin.assigned),
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

    var engine = try egress_engine.Engine.init(allocator, queueCapacity(cell, total_slots), .{
        .connector_count = cell.connectors,
    });
    // The gateway pre-registers receive buffers before starting its engine
    // (egress/gateway/engine.zig), so the bench measures that io_uring
    // data path unless the knob turns it off.
    engine.setPreRegisterRecvBuffers(cell.pre_register_recv_buffers);
    defer {
        // Queued body credits go back first, then `engine.deinit` stops the
        // engine, joining its threads and settling every pending task. Only
        // then are the chunk queues final: the second release drains them,
        // and `Task.deinit` asserts that its body holds no queued chunk.
        for (slots) |*slot| {
            if (slot.task) |task|
                releaseTaskCredits(context, &engine, task);
        }
        engine.deinit();
        for (slots) |*slot| {
            if (slot.task) |task| {
                releaseTaskCredits(context, &engine, task);
                destroyTask(context, task);
                slot.task = null;
            }
        }
    }

    // One untimed request per origin pays for the TLS handshake, the HTTP/2
    // session setup and the pool adoption. The origin answers its first
    // stream with an empty body, so the timed window below measures only
    // reuse of established connections.
    for (slots[0..origin_count], 0..) |*slot, index| {
        slot.* = .{ .origin_index = index };
        try submitSlot(context, &engine, slot, origins);
    }
    try driveLoop(context, &engine, slots[0..origin_count], origins, origin_count, .prime);

    context.ready_posted = true;
    context.ready_sem.post();
    context.go_event.wait();

    // A blocking wait that straddles the window boundary attributes its full
    // duration to wait_ns inside the window; negligible over a whole sample.
    const h2_stats_start = engine.snapshotH2Stats();

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
    const h2_stats_end = engine.snapshotH2Stats();
    context.h2 = .{
        .busy_ns = h2_stats_end.busy_ns -| h2_stats_start.busy_ns,
        .wait_ns = h2_stats_end.wait_ns -| h2_stats_start.wait_ns,
        .process_ns = h2_stats_end.process_ns -| h2_stats_start.process_ns,
        .maintain_ns = h2_stats_end.maintain_ns -| h2_stats_start.maintain_ns,
        .handle_ns = h2_stats_end.handle_ns -| h2_stats_start.handle_ns,
        .iterations = h2_stats_end.iterations -| h2_stats_start.iterations,
        .batch_messages = h2_stats_end.batch_messages_total -| h2_stats_start.batch_messages_total,
        .queue_depth_max = h2_stats_end.queue_depth_enqueue_max,
        .watch_list_len_max = h2_stats_end.watch_list_len_max,
    };

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
        destroyTask(context, task);
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
    errdefer destroyTask(context, task);
    slot.ttfb_ns = null;
    slot.submit_ns = try monotonicNowNs();
    try engine.submit(.{ .task = task, .config = context.config }, context, wakeFromEngine);
    slot.task = task;
}

fn createTask(context: *EngineContext, url: []const u8) !*task_model.Task {
    const allocator = context.allocator;
    context.next_task_id += 1;
    const id = context.next_task_id;
    const identity = bindings.FetchBodyIdentity{
        .request_id = id,
        .request_generation = 1,
        .fetch_id = id,
        .body_id = id,
    };
    const body = try allocator.create(fetch_body.Body);
    var body_owned = true;
    errdefer if (body_owned) {
        body.deinitAfterQueuedResourcesReleased(allocator);
        allocator.destroy(body);
    };
    body.* = fetch_body.Body.initOpen(allocator, identity, null);
    const task = try allocator.create(task_model.Task);
    errdefer allocator.destroy(task);
    task.* = try task_model.Task.init(
        allocator,
        id,
        id,
        url,
        "GET",
        "",
        &.{},
        0,
        identity,
        body,
    );
    body_owned = false;
    return task;
}

fn destroyTask(context: *EngineContext, task: *task_model.Task) void {
    task.deinit();
    context.allocator.destroy(task);
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
    task.response_body.releaseQueuedChunksCallback(context.allocator, &release, releaseCreditToEngine);
}

fn bodyState(body: *fetch_body.Body) fetch_body.State {
    body.mutex.lock();
    defer body.mutex.unlock();
    return body.state;
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
/// on response headers, but a clean body completion wakes only registered
/// body waiters, which this bench does not register, so the last completion
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

/// Sized so the credit releases, one engine command per released body chunk
/// and roughly one chunk per `origin_data_frame_bytes` DATA frame, never fill
/// the h2 command queue. `releaseFetchBodyCredit` blocks the releasing driver
/// thread while that queue is full, which would turn queue pressure into
/// latency the samples report.
fn queueCapacity(cell: Cell, total_slots: usize) usize {
    const chunks_per_response = cell.max_response_bytes / origin_data_frame_bytes + 4;
    return 2 * total_slots + cell.origins + 16 + total_slots * chunks_per_response;
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
    // A frozen owner makes no iterations while messages sit queued; an idle
    // owner that lost a wake or a credit has an empty queue and waits for an
    // event that never comes. Each in-flight slot's body state then shows
    // which stream the missing wake or credit belongs to.
    {
        const iterations_before = engine.h2_stats.iterations.load(.monotonic);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        const iterations_after = engine.h2_stats.iterations.load(.monotonic);
        engine.mutex.lock();
        const queue_len = engine.h2_len;
        const queue_capacity = engine.h2_queue.len;
        engine.mutex.unlock();
        std.debug.print(
            "DIAG stall engine[{d}]: owner_iterations {d}->{d} (alive={}) h2_queue {d}/{d}\n",
            .{
                context.engine_index,
                iterations_before,
                iterations_after,
                iterations_after != iterations_before,
                queue_len,
                queue_capacity,
            },
        );
        for (slots, 0..) |*slot, index| {
            const task = slot.task orelse continue;
            task.mutex.lock();
            const done = task.done;
            task.mutex.unlock();
            std.debug.print(
                "DIAG stall slot[{d}]: origin={d} done={} body_state={s} queued_decoded={d}\n",
                .{
                    index,
                    slot.origin_index,
                    done,
                    @tagName(bodyState(task.response_body)),
                    task.response_body.queuedDecodedBytes(),
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
        "{{\"bench\":\"egress_h2_engine\",\"mix\":\"{s}\",\"engines\":{d},\"h2_connectors\":{d},\"origins\":{d},\"streams\":{d},\"response_body_bytes\":{d},\"inflight\":{d},\"requests\":{d},\"iteration\":{d},\"elapsed_ns\":{d},\"req_per_s\":{d:.1},\"mb_per_s\":{d:.2},\"ttfb_p50_ns\":{d},\"ttfb_p99_ns\":{d},\"rss_kib\":{d},\"peak_rss_kib\":{d},\"h2_busy_pct\":{d:.1},\"h2_busy_pct_max\":{d:.1},\"h2_busy_ns\":{d},\"h2_wait_ns\":{d},\"h2_process_ns\":{d},\"h2_maintain_ns\":{d},\"h2_handle_ns\":{d},\"h2_iterations\":{d},\"h2_batch_messages\":{d},\"h2_queue_depth_max\":{d},\"h2_watch_list_len_max\":{d}}}\n",
        .{
            cell.mix_desc,
            cell.engines,
            cell.connectors,
            cell.origins,
            cell.streams,
            cell.response_bytes,
            cell.inflight,
            cell.requests,
            iteration,
            sample.elapsed_ns,
            sample.req_per_s,
            sample.mb_per_s,
            sample.ttfb_p50_ns,
            sample.ttfb_p99_ns,
            sample.rss_kib,
            sample.peak_rss_kib,
            sample.h2_busy_pct,
            sample.h2_busy_pct_max,
            sample.h2_busy_ns,
            sample.h2_wait_ns,
            sample.h2_process_ns,
            sample.h2_maintain_ns,
            sample.h2_handle_ns,
            sample.h2_iterations,
            sample.h2_batch_messages,
            sample.h2_queue_depth_max,
            sample.h2_watch_list_len_max,
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

const route_probe_ipv4 = "1.1.1.1";
const route_probe_port: u16 = 9;

fn routableLocalIpv4(out: *[64]u8) ![]const u8 {
    const address = try defaultRouteSourceAddress();
    (egress.EgressPolicy{ .allow_private_networks = true }).validateResolvedAddress(address) catch {
        std.debug.print("egress_h2_engine: default-route source address is not egress-permitted\n", .{});
        return error.BenchNoRoutableLocalAddress;
    };
    const bytes = egress.ipv4Bytes(address);
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
