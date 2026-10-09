//! The in-process runners behind `suites.zig`. Each run creates its own VM and
//! `worker.Runtime` on the test thread, with a fake monotonic clock and a
//! socket pair standing in for the host's control channel, serves the fixture
//! as a route, and expects the JSON result to report `ok`. No zygote, sandbox
//! or egress gateway takes part; `forked.zig` covers a forked worker.
//!
//! A Collo contract fixture is appended to `support/harness.js` and runs as one
//! route module. An exact Bun or WPT port keeps its own module: its `bun:test`,
//! `collo:test` and `harness` imports are rewritten to the specifiers of
//! `support/collo_test.js` and `support/compat_harness.js`, and all of them are
//! registered as permanent modules of one pack. A leak fixture runs as a count
//! request, then, for each test, a setup request, full collections and a check
//! request. Except in `runLeakSuite`, `COLLO_WEBAPI_TEST_FILTER` keeps only the
//! tests whose names contain its value.

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
const compat_leak_harness_specifier = "/__collo_route/" ++ deploy_hash ++ "/leak-harness.js";
const collo_test_entry_specifier = "/__collo_route/" ++ deploy_hash ++ "/webapi-compat-entry.js";
const collo_test_import = "collo" ++ ":test";
const bun_test_import = "bun" ++ ":test";
const compat_harness_import = "harness";
const webapi_test_filter_env = "COLLO_WEBAPI_TEST_FILTER";

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

    const request_id = requestIdForSpecifier(specifier);
    const response = try rt.runRouteAndReadBody(&runtime, control_pair[1], combined, request_id, specifier);
    defer std.testing.allocator.free(response);

    try expectSuiteOk(specifier, response);
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

    const count_request_id = requestIdForSpecifierWithSalt(specifier, 0xC017);
    const count_response = try rt.runRouteAndReadBodyWithRequest(
        &runtime,
        control_pair[1],
        combined,
        count_request_id,
        specifier,
        .{ .path = "/count" },
    );
    defer std.testing.allocator.free(count_response);
    try expectSuiteOk(specifier, count_response);
    const test_count = try leakSuiteTotal(count_response);

    for (0..test_count) |test_index| {
        {
            const setup_path = try std.fmt.allocPrint(std.testing.allocator, "/setup/{d}", .{test_index});
            defer std.testing.allocator.free(setup_path);

            const setup_response = try rt.runRouteAndReadBodyWithRequest(
                &runtime,
                control_pair[1],
                combined,
                requestIdForSpecifierWithSalt(specifier, 0x5E7A9 + test_index),
                specifier,
                .{ .path = setup_path },
            );
            defer std.testing.allocator.free(setup_response);
            try expectSuiteOk(specifier, setup_response);
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
            const check_response = try rt.runRouteAndReadBodyWithRequest(
                &runtime,
                control_pair[1],
                combined,
                requestIdForSpecifierWithSalt(specifier, 0xC0A11EC7 + test_index),
                specifier,
                .{ .path = "/check" },
            );
            defer std.testing.allocator.free(check_response);
            try expectSuiteOk(specifier, check_response);
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
    _ = try rt.registerRoutePack(&runtime, route_fd, collo_test_entry_specifier);

    const request_id = requestIdForSpecifier(specifier);
    const response = try rt.runRegisteredRouteAndReadBody(
        &runtime,
        control_pair[1],
        request_id,
        collo_test_entry_specifier,
        .{},
    );
    defer std.testing.allocator.free(response);

    try expectSuiteOk(specifier, response);
}

pub fn runCompatLeakSuite(source: []const u8, specifier: []const u8) !void {
    try runCompatLeakSuiteWithPrelude("", source, specifier);
}

pub fn runCompatLeakSuiteWithPrelude(prelude: []const u8, source: []const u8, specifier: []const u8) !void {
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
    const entry_source = try compatLeakEntrySource(std.testing.allocator, test_specifier);
    defer std.testing.allocator.free(entry_source);

    const empty_deps = [_]ipc.module_pack.Dependency{};
    const test_deps = [_]ipc.module_pack.Dependency{
        .{ .specifier = collo_test_specifier },
        .{ .specifier = compat_harness_specifier },
    };
    const entry_deps = [_]ipc.module_pack.Dependency{
        .{ .specifier = compat_leak_harness_specifier },
        .{ .specifier = test_specifier },
    };
    const modules = [_]ipc.module_pack.Module{
        .{
            .specifier = collo_test_specifier,
            .source = collo_test_source,
            .dependencies = &empty_deps,
        },
        .{
            .specifier = compat_harness_specifier,
            .source = compat_harness_source,
            .dependencies = &empty_deps,
        },
        .{
            .specifier = compat_leak_harness_specifier,
            .source = leak_harness_source,
            .dependencies = &empty_deps,
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
    const route_fd = try rt.createModulePackGraphFd(&modules, 4);
    defer std.posix.close(route_fd);
    _ = try rt.registerRoutePack(&runtime, route_fd, collo_test_entry_specifier);

    const count_response = try rt.runRegisteredRouteAndReadBody(
        &runtime,
        control_pair[1],
        requestIdForSpecifierWithSalt(specifier, 0xC017),
        collo_test_entry_specifier,
        .{ .path = "/count" },
    );
    defer std.testing.allocator.free(count_response);
    try expectSuiteOk(specifier, count_response);
    const test_count = try leakSuiteTotal(count_response);

    for (0..test_count) |test_index| {
        const setup_path = try std.fmt.allocPrint(std.testing.allocator, "/setup/{d}", .{test_index});
        defer std.testing.allocator.free(setup_path);

        const setup_response = try rt.runRegisteredRouteAndReadBody(
            &runtime,
            control_pair[1],
            requestIdForSpecifierWithSalt(specifier, 0x5E7A9 + test_index),
            collo_test_entry_specifier,
            .{ .path = setup_path },
        );
        defer std.testing.allocator.free(setup_response);
        try expectSuiteOk(specifier, setup_response);

        for (0..3) |_| {
            try vm.collectFullGCAndTrim();
        }

        const check_response = try rt.runRegisteredRouteAndReadBody(
            &runtime,
            control_pair[1],
            requestIdForSpecifierWithSalt(specifier, 0xC0A11EC7 + test_index),
            collo_test_entry_specifier,
            .{ .path = "/check" },
        );
        defer std.testing.allocator.free(check_response);
        try expectSuiteOk(specifier, check_response);
    }
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

fn expectSuiteOk(specifier: []const u8, response: []const u8) !void {
    const result = parseSuiteResult(response) catch {
        std.debug.print("webapi suite failed for {s}\n{s}\n", .{ specifier, response });
        return error.WebApiSuiteFailed;
    };
    if (!result.ok) {
        std.debug.print("webapi suite failed for {s}\n{s}\n", .{ specifier, response });
        return error.WebApiSuiteFailed;
    }
}

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

fn compatLeakEntrySource(allocator: std.mem.Allocator, test_specifier: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "import \"",
        compat_leak_harness_specifier,
        "\";\n",
        "import \"",
        test_specifier,
        "\";\n",
        "export default async function handle(req) {\n",
        "  let result;\n",
        "  if (req.path === \"/count\") {\n",
        "    result = { ok: true, total: globalThis.__colloWebApiLeakTestCount(), failures: [] };\n",
        "  } else if (req.path === \"/check\") {\n",
        "    result = await globalThis.__colloRunWebApiLeakChecks();\n",
        "  } else {\n",
        "    const match = /^\\/setup\\/(\\d+)$/.exec(req.path);\n",
        "    result = match\n",
        "      ? await globalThis.__colloRunWebApiLeakSetup(Number(match[1]))\n",
        "      : { ok: false, total: globalThis.__colloWebApiLeakTestCount(), failures: [{ name: \"leak route\", message: \"unknown leak route\" }] };\n",
        "  }\n",
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
