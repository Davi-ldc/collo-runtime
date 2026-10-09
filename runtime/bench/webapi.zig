//! Runs every WebAPI bench file under Collo and under Bun and prints one
//! comparison line per case the file reports. The Collo side runs in this
//! process, on its main thread: each file gets a fresh VM and a worker
//! runtime built in place, with no zygote, fork or sandbox, whose boot
//! evaluates the shared harness plus that file as its route, and one request
//! that answers with the results of all its cases as JSON. The Bun side
//! writes the same harness and bench file into one module under
//! `.zig-cache/webapi-bench/` in the working directory and runs Bun on it.
//! Bun is required, found through BUN_EXE or PATH. A case that either side
//! leaves out fails the run, so every printed ratio compares the same case.
//! COLLO_WEBAPI_BENCH_RUNS sets the runs per case.

const std = @import("std");
const bindings_support = @import("bindings_support");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const worker_shared_page = @import("collo_worker_state").page;
const build_options = @import("collo_bench_build_options");
const worker_ingress = @import("worker_ingress.zig");

const bench_harness_source = @embedFile("webapi_bench_harness_js");

const collo_runner_source =
    \\
    \\export default async function handle(req) {
    \\  const result = await __colloRunWebApiBenchmarks({ runtime: "collo", request: req, runs: globalThis.__colloBenchRuns });
    \\  return Response.json(result);
    \\}
;

const bun_runner_source =
    \\
    \\const result = await __colloRunWebApiBenchmarks({ runtime: "bun", runs: globalThis.__colloBenchRuns });
    \\console.log(JSON.stringify(result));
;

const request_headers = [_]ipc.RequestHeader{.{ .name = "host", .value = "demo.test" }};

const BenchSpec = struct {
    name: []const u8,
    specifier: []const u8,
    source: []const u8,
};

const bench_specs = [_]BenchSpec{
    .{ .name = "globals", .specifier = "/webapi/globals.bench.js", .source = @embedFile("webapi_globals_bench_js") },
    .{ .name = "dom_exception", .specifier = "/webapi/dom-exception.bench.js", .source = @embedFile("webapi_dom_exception_bench_js") },
    .{ .name = "event", .specifier = "/webapi/event.bench.js", .source = @embedFile("webapi_event_bench_js") },
    .{ .name = "message_channel", .specifier = "/webapi/message-channel.bench.js", .source = @embedFile("webapi_message_channel_bench_js") },
    .{ .name = "performance", .specifier = "/webapi/performance.bench.js", .source = @embedFile("webapi_performance_bench_js") },
    .{ .name = "abort", .specifier = "/webapi/abort.bench.js", .source = @embedFile("webapi_abort_bench_js") },
    .{ .name = "blob", .specifier = "/webapi/blob.bench.js", .source = @embedFile("webapi_blob_bench_js") },
    .{ .name = "file", .specifier = "/webapi/file.bench.js", .source = @embedFile("webapi_file_bench_js") },
    .{ .name = "formdata", .specifier = "/webapi/formdata.bench.js", .source = @embedFile("webapi_formdata_bench_js") },
    .{ .name = "formdata_multipart_body", .specifier = "/webapi/formdata-multipart-body.bench.js", .source = @embedFile("webapi_formdata_multipart_body_bench_js") },
    .{ .name = "crypto", .specifier = "/webapi/crypto.bench.js", .source = @embedFile("webapi_crypto_bench_js") },
    .{ .name = "structured_clone", .specifier = "/webapi/structured-clone.bench.js", .source = @embedFile("webapi_structured_clone_bench_js") },
    .{ .name = "report_error", .specifier = "/webapi/report-error.bench.js", .source = @embedFile("webapi_report_error_bench_js") },
    .{ .name = "navigator", .specifier = "/webapi/navigator.bench.js", .source = @embedFile("webapi_navigator_bench_js") },
    .{ .name = "console", .specifier = "/webapi/console.bench.js", .source = @embedFile("webapi_console_bench_js") },
    .{ .name = "text_codec", .specifier = "/webapi/text-codec.bench.js", .source = @embedFile("webapi_text_codec_bench_js") },
    .{ .name = "base64", .specifier = "/webapi/base64.bench.js", .source = @embedFile("webapi_base64_bench_js") },
    .{ .name = "microtask", .specifier = "/webapi/microtask.bench.js", .source = @embedFile("webapi_microtask_bench_js") },
    .{ .name = "url", .specifier = "/webapi/url.bench.js", .source = @embedFile("webapi_url_bench_js") },
    .{ .name = "url_search_params", .specifier = "/webapi/url-search-params.bench.js", .source = @embedFile("webapi_url_search_params_bench_js") },
    .{ .name = "url_pattern", .specifier = "/webapi/url-pattern.bench.js", .source = @embedFile("webapi_url_pattern_bench_js") },
    .{ .name = "headers", .specifier = "/webapi/headers.bench.js", .source = @embedFile("webapi_headers_bench_js") },
    .{ .name = "request", .specifier = "/webapi/request.bench.js", .source = @embedFile("webapi_request_bench_js") },
    .{ .name = "response", .specifier = "/webapi/response.bench.js", .source = @embedFile("webapi_response_bench_js") },
    .{ .name = "body", .specifier = "/webapi/body.bench.js", .source = @embedFile("webapi_body_bench_js") },
    .{ .name = "streams", .specifier = "/webapi/streams.bench.js", .source = @embedFile("webapi_streams_bench_js") },
    .{ .name = "streams_readable_stream_from", .specifier = "/webapi/streams-from.bench.js", .source = @embedFile("webapi_streams_readable_stream_from_bench_js") },
    .{ .name = "fetch", .specifier = "/webapi/fetch.bench.js", .source = @embedFile("webapi_fetch_args_bench_js") },
    .{ .name = "timers", .specifier = "/webapi/timers.bench.js", .source = @embedFile("webapi_timers_bench_js") },
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const run_count = try configuredBenchRunCount(allocator);
    printMetadata("webapi", run_count);

    const bun_exe = findBun(allocator) orelse {
        std.debug.print("webapi_bench bun_status=missing comparison=required\n", .{});
        return error.BunRequiredForWebApiBench;
    };
    defer allocator.free(bun_exe);

    for (bench_specs) |spec| {
        const collo_json = try runColloBench(allocator, spec, run_count);
        defer allocator.free(collo_json);

        const bun_json = runBunBench(allocator, bun_exe, spec, run_count) catch |err| {
            std.debug.print("webapi_bench api={s} bun_error={s}\n", .{ spec.name, @errorName(err) });
            return err;
        };
        defer allocator.free(bun_json);

        try printComparison(allocator, spec.name, collo_json, bun_json);
    }
}

fn printMetadata(bench_name: []const u8, run_count: u32) void {
    std.debug.print(
        "{{\"bench\":\"metadata\",\"benchmark\":\"{s}\",\"run_count\":{d},\"optimize_mode\":\"{s}\",\"target_arch\":\"{s}\",\"target_os\":\"{s}\",\"git_or_deploy_hash\":\"{s}\",\"timestamp_unix\":{d},\"final\":{s}}}\n",
        .{
            bench_name,
            run_count,
            build_options.optimize_mode_name,
            build_options.target_arch_name,
            build_options.target_os_name,
            build_options.git_or_deploy_hash,
            std.time.timestamp(),
            if (std.mem.eql(u8, build_options.optimize_mode_name, "ReleaseFast")) "true" else "false",
        },
    );
    if (!std.mem.eql(u8, build_options.optimize_mode_name, "ReleaseFast"))
        std.debug.print("NOT FINAL: benchmark was not built with ReleaseFast\n", .{});
}

fn configuredBenchRunCount(allocator: std.mem.Allocator) !u32 {
    const value = std.process.getEnvVarOwned(allocator, "COLLO_WEBAPI_BENCH_RUNS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return 3,
        else => return err,
    };
    defer allocator.free(value);

    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const parsed = std.fmt.parseUnsigned(u32, trimmed, 10) catch return error.InvalidBenchRunCount;
    if (parsed == 0)
        return error.InvalidBenchRunCount;
    return parsed;
}

fn findBun(allocator: std.mem.Allocator) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "BUN_EXE")) |value|
        return value
    else |_| {}

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", "command -v bun" },
        .max_output_bytes = 4096,
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term != .Exited or result.term.Exited != 0)
        return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0)
        return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn runColloBench(allocator: std.mem.Allocator, spec: BenchSpec, run_count: u32) ![]u8 {
    var vm = try bindings_support.createVm();
    defer vm.deinit();

    const control_pair = try fd_mod.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const metrics_fd = try worker_shared_page.createMemfd("collo-bench-webapi-metrics");
    defer std.posix.close(metrics_fd);
    var metrics_view = try worker_shared_page.mapReadWrite(metrics_fd);
    defer metrics_view.deinit();
    metrics_view.initializeCrashDefault(@intCast(std.os.linux.getpid()), 512 * 1024 * 1024, 0);
    const completion_eventfd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);

    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(allocator, &vm, control_pair[0], &metrics_view, completion_eventfd, .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const run_config_source = try benchRunConfigSource(allocator, run_count);
    defer allocator.free(run_config_source);

    const source = try std.mem.concat(allocator, u8, &.{
        run_config_source,
        bench_harness_source,
        "\n",
        spec.source,
        "\n",
        collo_runner_source,
    });
    defer allocator.free(source);

    return runRouteAndReadBody(
        allocator,
        &runtime,
        control_pair[1],
        source,
        requestIdForSpecifier(spec.specifier),
        spec.specifier,
    );
}

fn runBunBench(allocator: std.mem.Allocator, bun_exe: []const u8, spec: BenchSpec, run_count: u32) ![]u8 {
    try std.fs.cwd().makePath(".zig-cache/webapi-bench");
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/webapi-bench/{s}.mjs", .{spec.name});
    defer allocator.free(path);
    const run_config_source = try benchRunConfigSource(allocator, run_count);
    defer allocator.free(run_config_source);
    const source = try std.mem.concat(allocator, u8, &.{
        run_config_source,
        bench_harness_source,
        "\n",
        spec.source,
        "\n",
        bun_runner_source,
    });
    defer allocator.free(source);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = source });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ bun_exe, path },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("bun stderr for {s}:\n{s}\n", .{ spec.name, result.stderr });
        allocator.free(result.stdout);
        return error.BunBenchFailed;
    }
    return result.stdout;
}

fn benchRunConfigSource(allocator: std.mem.Allocator, run_count: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "globalThis.__colloBenchRuns = {d};\n", .{run_count});
}

fn printComparison(allocator: std.mem.Allocator, api_name: []const u8, collo_json: []const u8, bun_json: []const u8) !void {
    var collo_tree = try std.json.parseFromSlice(std.json.Value, allocator, collo_json, .{});
    defer collo_tree.deinit();

    var bun_tree = try std.json.parseFromSlice(std.json.Value, allocator, bun_json, .{});
    defer bun_tree.deinit();
    try printComparedResults(api_name, collo_tree.value, bun_tree.value);
}

fn printComparedResults(api_name: []const u8, collo: std.json.Value, bun: std.json.Value) !void {
    const collo_results = collo.object.get("results").?.array.items;
    const bun_results = bun.object.get("results").?.array.items;
    for (collo_results) |collo_result| {
        const name = collo_result.object.get("name").?.string;
        const collo_ns = meanNsPerOp(collo_result);
        const bun_result = findBenchResultByName(bun_results, name) orelse {
            std.debug.print(
                "webapi_bench api={s} case=\"{s}\" collo_mean_ns_per_op={d:.2} bun_mean_ns_per_op=missing ratio=missing error=\"bun result missing\"\n",
                .{ api_name, name, collo_ns },
            );
            return error.MissingBunBenchResult;
        };
        const bun_ns = meanNsPerOp(bun_result);
        std.debug.print(
            "webapi_bench api={s} case=\"{s}\" collo_runs_ns=",
            .{ api_name, name },
        );
        printRunNsList(collo_result);
        std.debug.print(
            " collo_mean_ns_per_op={d:.2} collo_stability_rsd_pct={d:.2} collo_spread_pct={d:.2} bun_runs_ns=",
            .{ collo_ns, percentField(collo_result, "relative_stddev_pct"), percentField(collo_result, "spread_pct") },
        );
        printRunNsList(bun_result);
        std.debug.print(
            " bun_mean_ns_per_op={d:.2} bun_stability_rsd_pct={d:.2} bun_spread_pct={d:.2} ratio_collo_over_bun={d:.3}\n",
            .{ bun_ns, percentField(bun_result, "relative_stddev_pct"), percentField(bun_result, "spread_pct"), collo_ns / bun_ns },
        );
    }
    for (bun_results) |bun_result| {
        const name = bun_result.object.get("name").?.string;
        if (findBenchResultByName(collo_results, name) != null)
            continue;
        std.debug.print(
            "webapi_bench api={s} case=\"{s}\" error=\"collo result missing\"\n",
            .{ api_name, name },
        );
        return error.MissingColloBenchResult;
    }
}

fn findBenchResultByName(results: []const std.json.Value, name: []const u8) ?std.json.Value {
    for (results) |result| {
        if (std.mem.eql(u8, result.object.get("name").?.string, name))
            return result;
    }
    return null;
}

fn meanNsPerOp(result: std.json.Value) f64 {
    if (result.object.get("mean_ns_per_op")) |value|
        return numberValue(value);
    return numberValue(result.object.get("ns_per_op").?);
}

fn percentField(result: std.json.Value, field: []const u8) f64 {
    if (result.object.get(field)) |value|
        return numberValue(value);
    return 0;
}

fn printRunNsList(result: std.json.Value) void {
    const runs_value = result.object.get("runs") orelse {
        std.debug.print("[{d:.2}]", .{meanNsPerOp(result)});
        return;
    };
    std.debug.print("[", .{});
    for (runs_value.array.items, 0..) |run, index| {
        if (index != 0)
            std.debug.print(",", .{});
        std.debug.print("{d:.2}", .{numberValue(run.object.get("ns_per_op").?)});
    }
    std.debug.print("]", .{});
}

fn numberValue(value: std.json.Value) f64 {
    return switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => 0,
    };
}

fn runRouteAndReadBody(
    allocator: std.mem.Allocator,
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
) ![]u8 {
    const route_fd = try std.posix.memfd_create(
        "webapi-bench-route",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    defer std.posix.close(route_fd);
    const route_specifier = try scopedRouteSpecifier(allocator, specifier);
    defer allocator.free(route_specifier);
    const pack = try ipc.module_pack.buildSingleAlloc(allocator, route_specifier, source);
    defer allocator.free(pack);
    try fd_mod.writeAllRaw(route_fd, pack);
    try std.posix.lseek_SET(route_fd, 0);
    try fd_mod.addSeals(route_fd, fd_mod.memfd_readonly_seals);

    // A worker's boot registers its definition's pack and evaluates every
    // route of the table WorkerInit carried before any request names one;
    // this runtime's table is the one route.
    const route_index = try runtime.modules.state.addRoute(allocator, route_specifier, &ipc.route_bindings.empty_blob);
    try runtime.evaluateBootRoutes(route_fd, 0, null);

    var dispatch = try ipc.DispatchWork.initOwned(allocator, .{
        .request_id = request_id,
        .request_generation = 1,
        .worker_id = 1,
        .worker_generation = 1,
        .request_lane_id = 0,
        .request_slot = 0,
        .accounting_flags = 0,
        .authority = "demo.test",
        .deadline_monotonic_ns = 30 * std.time.ns_per_s,
        .method = "GET",
        .path = "/bench",
        .raw_query = "",
        .request_headers = &request_headers,
        .body_framing = .none,
        .route_captures = &.{},
        .route_index = route_index,
    });
    defer dispatch.deinit();

    try worker_ingress.enqueueRoute(allocator, runtime, &dispatch, 1);
    const request_item = runtime.scheduler.ready_queue.pop() orelse return error.MissingRequestWork;
    try worker.executeWorkItem(runtime, request_item);
    try executeUntilRequestDone(runtime, request_id);

    var response = try worker_ingress.readResponse(allocator, server_control_fd, request_id, .{
        .completion_eventfd = runtime.egress.completion_eventfd,
        .metrics = runtime.observability.metrics_view,
    });
    defer response.deinit(allocator);
    return allocator.dupe(u8, response.body);
}

fn executeUntilRequestDone(runtime: *worker.Runtime, request_id: u64) !void {
    var attempts: usize = 0;
    while (runtime.requests.active.contains(request_id)) : (attempts += 1) {
        if (attempts > 10000)
            return error.RequestDidNotComplete;
        try runtime.collectCompletedCryptoJobs();
        try runtime.collectCompletedFetches();
        try runtime.collectReadyFetchBodies();
        try runtime.collectDueTimers();
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker.executeWorkItem(runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

fn scopedRouteSpecifier(allocator: std.mem.Allocator, specifier: []const u8) ![]u8 {
    if (ipc.module_pack.deployHashFromSpecifier(specifier) != null)
        return allocator.dupe(u8, specifier);
    const suffix = if (std.mem.startsWith(u8, specifier, "/")) specifier[1..] else specifier;
    return std.fmt.allocPrint(allocator, "/__collo_route/bench/{s}", .{suffix});
}

fn requestIdForSpecifier(specifier: []const u8) u64 {
    const hash = std.hash.Wyhash.hash(0xC0110, specifier);
    return if (hash == 0) 1 else hash;
}

fn fakeNow(ctx: ?*anyopaque) u64 {
    return @as(*u64, @ptrCast(@alignCast(ctx.?))).*;
}
