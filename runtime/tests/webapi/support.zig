//! The in-process runners behind `suites.zig`. Each run creates its own VM and
//! `worker.Runtime` on the test thread, with a fake monotonic clock and a
//! socket pair standing in for the host's control channel, serves the fixture
//! as a route, and expects the JSON result to report `ok` with at least one
//! test. No zygote, sandbox or egress gateway takes part; `forked.zig` covers a
//! forked worker.
//!
//! A Collo contract fixture is appended to `support/harness.js` and runs as one
//! route module. An exact Bun or WPT port keeps its own module: its `bun:test`,
//! `collo:test` and `harness` imports are rewritten to the specifiers of
//! `support/collo_test.js` and `support/compat_harness.js`, and all of them are
//! registered as permanent modules of one pack. A leak fixture runs as a count
//! request, then, for each test, a setup request, full collections and a check
//! request. Except in `runLeakSuite`, `COLLO_WEBAPI_TEST_FILTER` keeps only the
//! tests whose names contain its value, and only a filtered suite may end up
//! with no test.
//!
//! Every request runs on the fake clock through
//! `executeUntilRequestDoneOnFakeClock`, which moves it while the suite works
//! and while it waits, so timers fire, and with them each harness's timeout,
//! which fails a hung test, hook or leak step by name. A suite still running
//! after `suite_budget_ns` of fake time, a request that neither finishes nor
//! is ended by its own timers, fails without a result.

const std = @import("std");
const bindings_support = @import("bindings_support");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const harness_source = @embedFile("support/harness.js");
const leak_harness_source = @embedFile("support/leak_harness.js");
const collo_test_source = @embedFile("support/collo_test.js");
const compat_harness_source = @embedFile("support/compat_harness.js");
// The hash segment after the `/__collo_route/` prefix. The bridge's
// `registerModulePackLocked` (`runtime/src/bindings/jsc/runtime/module_loader.cpp`)
// refuses a pack whose specifiers carry two different hashes, and a VM
// refuses any hash but the first it registered, so every prefixed specifier
// built here shares this one.
const deploy_hash = "test";
const collo_test_specifier = "/__collo_route/" ++ deploy_hash ++ "/collo-test.js";
const compat_harness_specifier = "/__collo_route/" ++ deploy_hash ++ "/harness.js";
const collo_test_entry_specifier = "/__collo_route/" ++ deploy_hash ++ "/webapi-compat-entry.js";
const collo_test_import = "collo" ++ ":test";
const bun_test_import = "bun" ++ ":test";
const compat_harness_import = "harness";
const webapi_test_filter_env = "COLLO_WEBAPI_TEST_FILTER";

/// The fake time one request of a suite may take. Each harness gives a test,
/// a hook and a leak step 5 s of it before failing it by name
/// (`support/harness.js`, `support/collo_test.js`), so a suite reaches this
/// bound only through work outside every harness timeout: work that keeps the
/// ready queue full, or a wait on something that never arrives.
const suite_budget_ns: u64 = 120 * std.time.ns_per_s;
/// How far past the budget the request's deadline lies, so the loop's bound,
/// and not a 504, ends a suite that never finishes.
const suite_deadline_margin_ns: u64 = std.time.ns_per_s;

const runner_source =
    \\
    \\export default async function handle() {
    \\  const result = await __colloRunWebApiTests();
    \\  return new Response(JSON.stringify(result), {
    \\    status: result.ok ? 200 : 500,
    \\    headers: { "content-type": "application/json" },
    \\  });
    \\}
;

const leak_runner_source =
    \\
    \\export default async function handle(req) {
    \\  let result;
    \\  if (req.path === "/count") {
    \\    result = { ok: true, total: __colloWebApiLeakTestCount(), failures: [] };
    \\  } else if (req.path === "/check") {
    \\    result = await __colloRunWebApiLeakChecks();
    \\  } else {
    \\    const match = /^\/setup\/(\d+)$/.exec(req.path);
    \\    result = match
    \\      ? await __colloRunWebApiLeakSetup(Number(match[1]))
    \\      : { ok: false, total: __colloWebApiLeakTestCount(), failures: [{ name: "leak route", message: "unknown leak route" }] };
    \\  }
    \\  return new Response(JSON.stringify(result), {
    \\    status: result.ok ? 200 : 500,
    \\    headers: { "content-type": "application/json" },
    \\  });
    \\}
;

pub fn runSuite(source: []const u8, specifier: []const u8) !void {
    try runSuiteWithPrelude("", source, specifier);
}

pub fn runSuiteWithPrelude(prelude: []const u8, source: []const u8, specifier: []const u8) !void {
    var vm = try bindings_support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const filter_prelude = try webApiTestFilterPrelude(std.testing.allocator);
    defer std.testing.allocator.free(filter_prelude);

    const combined = try std.mem.concat(std.testing.allocator, u8, &.{
        harness_source,
        "\n",
        filter_prelude,
        "\n",
        prelude,
        "\n",
        source,
        "\n",
        runner_source,
    });
    defer std.testing.allocator.free(combined);

    const route_index = try registerSuiteRoute(&runtime, specifier, combined);
    const response = try runSuiteRequest(&runtime, control_pair[1], &now_mono_ns, .{
        .specifier = specifier,
        .route_index = route_index,
        .request_id = requestIdForSpecifier(specifier),
    });
    defer std.testing.allocator.free(response);

    try expectSuiteResult(specifier, response, .filterable);
}

pub fn runLeakSuite(source: []const u8, specifier: []const u8) !void {
    var vm = try bindings_support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const combined = try std.mem.concat(std.testing.allocator, u8, &.{
        harness_source,
        "\n",
        leak_harness_source,
        "\n",
        source,
        "\n",
        leak_runner_source,
    });
    defer std.testing.allocator.free(combined);

    const route_index = try registerSuiteRoute(&runtime, specifier, combined);
    const count_response = try runSuiteRequest(&runtime, control_pair[1], &now_mono_ns, .{
        .specifier = specifier,
        .route_index = route_index,
        .request_id = requestIdForSpecifierWithSalt(specifier, 0xC017),
        .request = .{ .path = "/count" },
    });
    defer std.testing.allocator.free(count_response);
    try expectSuiteResult(specifier, count_response, .complete);
    const test_count = try leakSuiteTotal(count_response);

    for (0..test_count) |test_index| {
        {
            const setup_path = try std.fmt.allocPrint(std.testing.allocator, "/setup/{d}", .{test_index});
            defer std.testing.allocator.free(setup_path);

            const setup_response = try runSuiteRequest(&runtime, control_pair[1], &now_mono_ns, .{
                .specifier = specifier,
                .route_index = route_index,
                .request_id = requestIdForSpecifierWithSalt(specifier, 0x5E7A9 + test_index),
                .request = .{ .path = setup_path },
            });
            defer std.testing.allocator.free(setup_response);
            try expectSuiteResult(specifier, setup_response, .complete);
        }

        // A WeakRef keeps its target alive until the current job ends
        // (ECMA-262 ClearKeptObjects), so a leak test sets up in one request
        // and checks in the next. The bridge refuses a full collection inside
        // a turn, so the harness collects here, between the two requests,
        // and JavaScript gets no `gc()` hook.
        for (0..3) |_| {
            try vm.collectFullGCAndTrim();
        }

        {
            const check_response = try runSuiteRequest(&runtime, control_pair[1], &now_mono_ns, .{
                .specifier = specifier,
                .route_index = route_index,
                .request_id = requestIdForSpecifierWithSalt(specifier, 0xC0A11EC7 + test_index),
                .request = .{ .path = "/check" },
            });
            defer std.testing.allocator.free(check_response);
            try expectSuiteResult(specifier, check_response, .complete);
        }
    }
}

pub fn runCompatSuite(source: []const u8, specifier: []const u8) !void {
    try runCompatSuiteWithPrelude("", source, specifier);
}

pub fn runCompatSuiteWithPrelude(prelude: []const u8, source: []const u8, specifier: []const u8) !void {
    var vm = try bindings_support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try initRuntime(&vm, control_pair[0], &completion_fixture, &now_mono_ns);
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const test_specifier = try normalizedCompatSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(test_specifier);
    const filter_prelude = try webApiTestFilterPrelude(std.testing.allocator);
    defer std.testing.allocator.free(filter_prelude);
    const source_with_prelude = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ filter_prelude, "\n", prelude, "\n", source },
    );
    defer std.testing.allocator.free(source_with_prelude);
    const rewritten_source = try rewriteColloTestImports(std.testing.allocator, source_with_prelude);
    defer std.testing.allocator.free(rewritten_source);
    const entry_source = try compatEntrySource(std.testing.allocator, test_specifier);
    defer std.testing.allocator.free(entry_source);

    const runner_deps = [_]ipc.module_pack.Dependency{};
    const test_deps = [_]ipc.module_pack.Dependency{
        .{ .specifier = collo_test_specifier },
        .{ .specifier = compat_harness_specifier },
    };
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
            .specifier = compat_harness_specifier,
            .source = compat_harness_source,
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
    const route_fd = try rt.createModulePackGraphFd(&modules, 3);
    defer std.posix.close(route_fd);
    const route_index = try rt.registerRoutePack(&runtime, route_fd, collo_test_entry_specifier);

    const response = try runSuiteRequest(&runtime, control_pair[1], &now_mono_ns, .{
        .specifier = specifier,
        .route_index = route_index,
        .request_id = requestIdForSpecifier(specifier),
    });
    defer std.testing.allocator.free(response);

    try expectSuiteResult(specifier, response, .filterable);
}

/// Registers `source` as the suite's route at `specifier` (`rt.routeSpecifier`)
/// unless the runtime already holds it, and returns its index.
fn registerSuiteRoute(runtime: *worker.Runtime, specifier: []const u8, source: []const u8) !u16 {
    const route_specifier = try rt.routeSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(route_specifier);
    return rt.registerRoute(runtime, route_specifier, source);
}

const SuiteRequest = struct {
    /// Names the suite in a failure.
    specifier: []const u8,
    route_index: u16,
    request_id: u64,
    request: rt.RequestParts = .{},
};

/// Runs one request of a suite to completion on the runtime's fake clock at
/// `now_mono_ns` and returns the response body, which the caller owns.
fn runSuiteRequest(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    now_mono_ns: *u64,
    suite_request: SuiteRequest,
) ![]u8 {
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = suite_request.request_id,
        .route_index = suite_request.route_index,
        .deadline_monotonic_ns = now_mono_ns.* + suite_budget_ns + suite_deadline_margin_ns,
        .request = suite_request.request,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, suite_request.request);
    try rt.executeQueuedBegin(runtime);
    rt.executeUntilRequestDoneOnFakeClock(runtime, now_mono_ns, suite_request.request_id, .{
        .budget_ns = suite_budget_ns,
    }) catch |err| switch (err) {
        error.RequestDidNotComplete => {
            std.debug.print(
                "webapi suite {s} sent no result within {d} s of fake time; a hung test, hook or leak step fails by name at its harness timeout, so work outside every timeout keeps the ready queue full or waits on something that never arrives\n",
                .{ suite_request.specifier, suite_budget_ns / std.time.ns_per_s },
            );
            return error.WebApiSuiteDidNotComplete;
        },
        else => return err,
    };
    return rt.readIngressResponseBody(runtime, server_control_fd, suite_request.request_id);
}

fn requestIdForSpecifier(specifier: []const u8) u64 {
    return requestIdForSpecifierWithSalt(specifier, 0xC0110);
}

/// Hashes `specifier` with `salt`. Each request of one runtime passes its own
/// salt, so their ids differ. Never zero, which the worker runtime reads as no
/// request.
fn requestIdForSpecifierWithSalt(specifier: []const u8, salt: u64) u64 {
    const hash = std.hash.Wyhash.hash(salt, specifier);
    return if (hash == 0) 1 else hash;
}

fn webApiTestFilterPrelude(allocator: std.mem.Allocator) ![]u8 {
    const filter = std.process.getEnvVarOwned(allocator, webapi_test_filter_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(filter);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("globalThis.__colloWebApiTestFilter = ");
    try std.json.Stringify.value(filter, .{}, &out.writer);
    try out.writer.writeAll(";\n");
    return out.toOwnedSlice();
}

fn initRuntime(
    vm: *bindings.Vm,
    control_fd: std.posix.fd_t,
    completion_fixture: *rt.CompletionFixture,
    now_mono_ns: *u64,
) !worker.Runtime {
    return worker.Runtime.init(std.testing.allocator, vm, control_fd, &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = now_mono_ns,
        .now_fn = rt.fakeNow,
    });
}

/// Whether `COLLO_WEBAPI_TEST_FILTER` reaches a suite's registrations.
pub const FilterScope = enum {
    /// The filter selects the suite's tests, so while it is set the suite may
    /// select none.
    filterable,
    /// Every test registers, so a suite with none is broken.
    complete,
};

/// Fails, printing the response, unless `response` is a suite result that
/// reports `ok` with at least one test. A suite with no test passes only when
/// the filter variable is set and reaches it: an empty suite otherwise means a
/// fixture that lost its tests, or a filter that matches nothing.
pub fn expectSuiteResult(specifier: []const u8, response: []const u8, scope: FilterScope) !void {
    const result = parseSuiteResult(response) catch {
        std.debug.print("webapi suite failed for {s}\n{s}\n", .{ specifier, response });
        return error.WebApiSuiteFailed;
    };
    if (!result.ok) {
        std.debug.print("webapi suite failed for {s}\n{s}\n", .{ specifier, response });
        return error.WebApiSuiteFailed;
    }
    if (result.total != 0) return;
    switch (scope) {
        .filterable => if (webApiTestFilterIsSet()) return,
        .complete => {},
    }
    std.debug.print("webapi suite {s} registered no test\n{s}\n", .{ specifier, response });
    return error.WebApiSuiteEmpty;
}

fn webApiTestFilterIsSet() bool {
    const filter = std.posix.getenv(webapi_test_filter_env) orelse return false;
    return filter.len != 0;
}

/// A result without `total` reads as an empty suite.
const SuiteResult = struct {
    ok: bool,
    total: usize = 0,
};

fn parseSuiteResult(response: []const u8) !SuiteResult {
    var parsed = try std.json.parseFromSlice(
        SuiteResult,
        std.testing.allocator,
        response,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    return parsed.value;
}

fn leakSuiteTotal(response: []const u8) !usize {
    return (try parseSuiteResult(response)).total;
}

fn normalizedCompatSpecifier(allocator: std.mem.Allocator, specifier: []const u8) ![]u8 {
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
    const replacements = [_]struct { needle: []const u8, replacement: []const u8 }{
        .{ .needle = "from \"" ++ collo_test_import ++ "\"", .replacement = "from \"" ++ collo_test_specifier ++ "\"" },
        .{ .needle = "from '" ++ collo_test_import ++ "'", .replacement = "from '" ++ collo_test_specifier ++ "'" },
        .{ .needle = "from \"" ++ bun_test_import ++ "\"", .replacement = "from \"" ++ collo_test_specifier ++ "\"" },
        .{ .needle = "from '" ++ bun_test_import ++ "'", .replacement = "from '" ++ collo_test_specifier ++ "'" },
        .{ .needle = "from \"" ++ compat_harness_import ++ "\"", .replacement = "from \"" ++ compat_harness_specifier ++ "\"" },
        .{ .needle = "from '" ++ compat_harness_import ++ "'", .replacement = "from '" ++ compat_harness_specifier ++ "'" },
    };

    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);
    for (replacements) |replacement| {
        const next = try replaceAll(allocator, current, replacement.needle, replacement.replacement);
        allocator.free(current);
        current = next;
    }
    return current;
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

test "a suite result passes only when it reports ok with at least one test" {
    try expectSuiteResult("/webapi/unit.test.js", "{\"ok\":true,\"total\":3,\"failures\":[]}", .complete);
    try std.testing.expectError(
        error.WebApiSuiteEmpty,
        expectSuiteResult("/webapi/unit.test.js", "{\"ok\":true,\"total\":0,\"failures\":[]}", .complete),
    );
    try std.testing.expectError(
        error.WebApiSuiteEmpty,
        expectSuiteResult("/webapi/unit.test.js", "{\"ok\":true}", .complete),
    );
    try std.testing.expectError(
        error.WebApiSuiteFailed,
        expectSuiteResult("/webapi/unit.test.js", "{\"ok\":false,\"total\":3,\"failures\":[]}", .complete),
    );
    try std.testing.expectError(
        error.WebApiSuiteFailed,
        expectSuiteResult("/webapi/unit.test.js", "504 deadline", .complete),
    );
}

test "webapi compat import rewriting accepts Bun test and harness imports" {
    const source =
        \\import { test, expect } from "bun:test";
        \\import { readableStreamFromArray } from "harness";
        \\test("portable stream helper", () => {
        \\  expect(readableStreamFromArray([])).toBeInstanceOf(ReadableStream);
        \\});
    ;
    const rewritten = try rewriteColloTestImports(std.testing.allocator, source);
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"harness\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, collo_test_specifier) != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, compat_harness_specifier) != null);
}

test "webapi compat import rewriting keeps already ported collo test imports" {
    const source =
        \\import { test } from "collo:test";
        \\test("already ported", () => {});
    ;
    const rewritten = try rewriteColloTestImports(std.testing.allocator, source);
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"collo:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, collo_test_specifier) != null);
}
