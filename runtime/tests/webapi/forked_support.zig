//! Runs one web API compat suite inside a worker forked from a real zygote
//! and booted through its sandbox. The suite's module, `support/collo_test.js`
//! and an entry route that runs the suite and answers with its JSON result
//! travel as one module pack in WorkerInit's route entry, and the response to
//! one request must report `"ok":true`. The worker launches attached to an
//! in-process egress gateway (`rt.LocalEgressGateway`) with a boot token, as
//! a launch with an egress grant does, and the suite's fetches run under
//! `rt.local_origin_network`, plain HTTP to private addresses; the test thread
//! plays the host. A missing delegated cgroup subtree skips the suite.
//! `forked.zig` names the suites run this way, and `support.zig` runs the
//! fixtures in process.

const std = @import("std");
const ipc = @import("collo_ipc");
const process = @import("collo_os").process;
const zygote_support = @import("zygote_support");
const host = zygote_support.host;

const rt = @import("collo_test_harness");

const worker_memory_limit_bytes: u64 = 1024 * 1024 * 1024;
// Every prefixed specifier in the pack shares this hash segment, because the
// bridge refuses a pack whose specifiers carry two
// (`registerModulePackLocked` in `bindings/jsc/runtime/module_loader.cpp`).
const deploy_hash = "test";
const collo_test_source = @embedFile("support/collo_test.js");
const collo_test_specifier = "/__collo_route/" ++ deploy_hash ++ "/collo-test.js";
const collo_test_entry_specifier = "/__collo_route/" ++ deploy_hash ++ "/webapi-fork-entry.js";
const collo_test_import = "collo" ++ ":test";

/// Runs the suite module `source`, registered at `specifier` below the pack's
/// hash segment. Fails with `error.ForkedWebApiSuiteFailed`, after printing
/// the response body, when the suite does not report `"ok":true`, and skips
/// when this environment cannot place workers.
pub fn runCompatSuite(source: []const u8, specifier: []const u8) !void {
    var spawned = try zygote_support.spawnZygote();
    defer spawned.deinit();

    var gateway = try rt.LocalEgressGateway.start(std.testing.allocator, .{
        .network = rt.local_origin_network,
    });
    defer gateway.deinit();
    var egress_shared_fds = gateway.takeWorkerSharedFds();
    defer egress_shared_fds.close();

    const test_specifier = try normalizedDeployTestSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(test_specifier);
    const rewritten_source = try rewriteColloTestImports(std.testing.allocator, source);
    defer std.testing.allocator.free(rewritten_source);
    const entry_source = try compatEntrySource(std.testing.allocator, test_specifier);
    defer std.testing.allocator.free(entry_source);

    const runner_deps = [_]ipc.module_pack.Dependency{};
    const test_deps = [_]ipc.module_pack.Dependency{.{ .specifier = collo_test_specifier }};
    const entry_deps = [_]ipc.module_pack.Dependency{
        .{ .specifier = test_specifier },
        .{ .specifier = collo_test_specifier },
    };
    const modules = [_]ipc.module_pack.Module{
        .{
            .specifier = collo_test_specifier,
            .source = collo_test_source,
            .dependencies = &runner_deps,
        },
        .{
            .specifier = test_specifier,
            .source = rewritten_source,
            .dependencies = &test_deps,
        },
        .{
            .specifier = collo_test_entry_specifier,
            .source = entry_source,
            .dependencies = &entry_deps,
        },
    };

    const route_fd = try rt.createModulePackGraphFd(&modules, 2);
    defer std.posix.close(route_fd);

    const request_id = requestIdForSpecifier(specifier);
    var launched = zygote_support.launchWorker(
        std.testing.allocator,
        &spawned,
        worker_memory_limit_bytes,
        request_id,
        .{
            .egress = .{ .attached = .{
                .shared_fds = egress_shared_fds,
                .boot = rt.localBootEgress(),
            } },
            .route_entry = .{ .fd = route_fd, .specifier = collo_test_entry_specifier },
        },
    ) catch |err| switch (err) {
        error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer launched.deinit();
    const handle = &launched.handle;

    // One budget for both ends: the worker's request deadline and how long
    // the host waits for the completion.
    const request_budget_ms: u32 = 30_000;
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_entry_specifier = collo_test_entry_specifier,
        // The forked worker reads the real monotonic clock, and the harness
        // default (`DispatchParts.deadline_monotonic_ns`) is an instant on
        // the in-process fake clock, long past on the real one.
        .deadline_monotonic_ns = (try process.monotonicNowNs()) + @as(u64, request_budget_ms) * std.time.ns_per_ms,
        .request = .{},
    });
    defer dispatch.deinit();
    try rt.sendIngressRoute(handle.control_fd, &dispatch, 1, .{});

    var response = try host.dispatch.readResponse(
        std.testing.allocator,
        handle.completionChannels(),
        request_id,
        .{
            .wall_ms = request_budget_ms,
            .max_body_bytes = rt.default_read_max_body_bytes,
            .max_headers_bytes = rt.default_read_max_headers_bytes,
        },
    );
    defer response.deinit();
    if (!std.mem.containsAtLeast(u8, response.body, 1, "\"ok\":true")) {
        std.debug.print("forked webapi suite failed for {s}\n{s}\n", .{ specifier, response.body });
        return error.ForkedWebApiSuiteFailed;
    }
}

/// A nonzero id derived from the suite's specifier. It doubles as the fork
/// job id, so each suite gets a cgroup leaf named after it.
fn requestIdForSpecifier(specifier: []const u8) u64 {
    const hash = std.hash.Wyhash.hash(0xC0110, specifier);
    return if (hash == 0) 1 else hash;
}

fn normalizedDeployTestSpecifier(allocator: std.mem.Allocator, specifier: []const u8) ![]u8 {
    const trimmed = std.mem.trimLeft(u8, specifier, "/");
    if (trimmed.len == 0)
        return error.InvalidWebApiCompatSpecifier;
    return std.fmt.allocPrint(allocator, "/__collo_route/" ++ deploy_hash ++ "/{s}", .{trimmed});
}

fn compatEntrySource(allocator: std.mem.Allocator, test_specifier: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "import \"",
        test_specifier,
        "\";\n",
        "import { __colloRunWebApiTests } from \"",
        collo_test_specifier,
        "\";\n",
        "export default async function handle() {\n",
        "  const result = await __colloRunWebApiTests();\n",
        "  return new Response(JSON.stringify(result), {\n",
        "    status: result.ok ? 200 : 500,\n",
        "    headers: { \"content-type\": \"application/json\" },\n",
        "  });\n",
        "}\n",
    });
}

fn rewriteColloTestImports(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const double_rewritten = try replaceAll(allocator, source, "from \"" ++ collo_test_import ++ "\"", "from \"" ++ collo_test_specifier ++ "\"");
    defer allocator.free(double_rewritten);
    return replaceAll(allocator, double_rewritten, "from '" ++ collo_test_import ++ "'", "from '" ++ collo_test_specifier ++ "'");
}

fn replaceAll(allocator: std.mem.Allocator, source: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var out = std.array_list.Aligned(u8, null).empty;
    errdefer out.deinit(allocator);

    var remaining = source;
    while (std.mem.indexOf(u8, remaining, needle)) |index| {
        try out.appendSlice(allocator, remaining[0..index]);
        try out.appendSlice(allocator, replacement);
        remaining = remaining[index + needle.len ..];
    }
    try out.appendSlice(allocator, remaining);
    return out.toOwnedSlice(allocator);
}
