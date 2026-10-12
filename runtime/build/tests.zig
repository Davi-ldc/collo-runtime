//! All test steps. Step names are stable; `test` aggregates the full JSC
//! suite, the WebAPI suites among them, plus every JSC-free deterministic
//! suite. The kernel lanes (zygote-integration, local-e2e) need the delegated
//! cgroup subtree and stay out of `test`, as do the two `bindings-gc-stress`
//! profiles, which rerun part of the aggregate binary under collector
//! debugging options, and test-bindings-valgrind; `smoke` (smoke.zig) runs
//! `test`, both GC stress profiles and both kernel lanes with strict skips.
//!
//! Every suite except the two bindings smokes runs under the custom runner
//! (runtime/tests/support/test_runner.zig), and every run is handed its suite
//! root and the skip allowlist, so COLLO_TEST_STRICT_SKIPS=1 in the caller's
//! environment makes any lane strict. A run made only for `smoke` sets the
//! variable itself.
const std = @import("std");
const codecs_mod = @import("codecs.zig");
const context_mod = @import("context.zig");
const link_mod = @import("link.zig");
const modules_mod = @import("modules.zig");
const shims = @import("shims.zig");
const skip_allowlist = @import("../tests/support/skip_allowlist.zig");

const ModuleId = modules_mod.ModuleId;

/// Read by the runner only when skips are strict.
const skip_allowlist_path = "runtime/tests/support/skip_allowlist.zon";

/// The test steps other build files extend or order.
pub const Lanes = struct {
    aggregate: Aggregate,
    /// Both `bindings-gc-stress` profiles, zygote-integration and local-e2e
    /// with strict skips, gated like the aggregate's strict runs; smoke.zig
    /// orders them.
    strict_gc_stress: StrictGcStress,
    strict_zygote_integration: *std.Build.Step.Run,
    strict_local_e2e: *std.Build.Step.Run,
};

/// `zig build test` and its strict twin. Each suite joins both: once as
/// `test` runs it, with skips as the caller's environment says, and once with
/// COLLO_TEST_STRICT_SKIPS=1, waiting on `strict_gate`. The twin is a
/// hidden step that completes when all its runs pass.
pub const Aggregate = struct {
    step: *std.Build.Step,
    strict: *std.Build.Step,
    strict_gate: *std.Build.Step,

    /// Adds a dependency that runs no tests, such as `check`, to both faces.
    pub fn dependOn(aggregate: Aggregate, step: *std.Build.Step) void {
        aggregate.step.dependOn(step);
        aggregate.strict.dependOn(step);
    }

    /// Runs `suite` in both faces and returns the run `test` makes, for other
    /// lanes that share it.
    pub fn addRun(
        aggregate: Aggregate,
        b: *std.Build,
        ctx: *const context_mod.Context,
        suite: RunnerSuite,
    ) *std.Build.Step.Run {
        const run = addRunnerRun(b, ctx, suite, .inherited);
        aggregate.step.dependOn(&run.step);
        const strict_run = addRunnerRun(b, ctx, suite, .{ .strict = aggregate.strict_gate });
        aggregate.strict.dependOn(&strict_run.step);
        return run;
    }
};

/// A test compilation built with the custom runner.
pub const RunnerSuite = struct {
    /// Its root source file names the suite for the skip allowlist.
    compile: *std.Build.Step.Compile,
    /// The executable link.zig links from `compile`'s object; null when
    /// `compile` links itself.
    linked: ?link_mod.LinkedArtifact = null,
    configured_args: []const []const u8 = &.{},
    /// The tests spawn the installed `collo` as their zygote. They know it by
    /// a plain path string, so the run waits on an install the object does
    /// not depend on.
    spawns_collo: bool = false,
    /// See enableReleaseOnlyTests.
    release_only_tests: bool = false,
};

const Skips = union(enum) {
    /// Whatever COLLO_TEST_STRICT_SKIPS the caller's environment holds.
    inherited,
    /// Strict, after the gate step passes.
    strict: *std.Build.Step,
};

/// `strict_gate` is the step every strict run waits on (smoke.zig's preflight).
pub fn addAll(
    b: *std.Build,
    ctx: *const context_mod.Context,
    strict_gate: *std.Build.Step,
) Lanes {
    const aggregate: Aggregate = .{
        .step = b.step("test", "Run the full test suite"),
        .strict = addHiddenStep(b, "test with strict skips"),
        .strict_gate = strict_gate,
    };
    aggregate.dependOn(ctx.webapi_contract_step);

    // `check` (built in build.zig, shared with the bench lane) type-checks
    // every root without linking or running any of them.
    //
    // It cannot catch a generic whose body nothing instantiates: Zig analyses
    // an `anytype` function only at a call site, so a `supervisor: anytype`
    // helper reached from no live root is invisible here. That gap closes as
    // those parameters become concrete types, not by anything the build can do.
    aggregate.dependOn(ctx.check_step);

    const fixtures = createTestFixtureModules(b, ctx);
    const main_suite = addMainSuite(b, ctx, aggregate, fixtures);
    const strict_gc_stress = addGcStressLane(b, ctx, main_suite, strict_gate);
    addGatewayControlSuite(b, ctx, aggregate);
    addSanitizedSmoke(b, ctx);
    addValgrindSmoke(b, ctx);
    const strict_zygote_integration = addZygoteIntegration(b, ctx, fixtures.test_harness, strict_gate);
    const strict_local_e2e = addLocalE2e(b, ctx, fixtures.test_harness, fixtures.tls_test_shim, strict_gate);
    addH2TransportSuites(b, ctx, aggregate, fixtures);
    addWslConfigSuite(b, ctx, aggregate);
    return .{
        .aggregate = aggregate,
        .strict_gc_stress = strict_gc_stress,
        .strict_zygote_integration = strict_zygote_integration,
        .strict_local_e2e = strict_local_e2e,
    };
}

/// One run of `suite` under the custom runner. The runner reads the
/// allowlist only when skips are strict, so passing it to every run costs
/// nothing and lets the caller's environment turn any lane strict.
fn addRunnerRun(
    b: *std.Build,
    ctx: *const context_mod.Context,
    suite: RunnerSuite,
    skips: Skips,
) *std.Build.Step.Run {
    const suite_root = suiteRoot(suite.compile);
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(b.allocator, suite.configured_args) catch @panic("OOM");
    args.append(b.allocator, b.fmt("--suite={s}", .{suite_root})) catch @panic("OOM");
    args.append(
        b.allocator,
        b.fmt("--skip-allowlist={s}", .{b.pathFromRoot(skip_allowlist_path)}),
    ) catch @panic("OOM");

    const run = if (suite.linked) |linked|
        link_mod.runLinkedExecutable(b, linked, ctx.opts.sanitizer, args.items)
    else run: {
        const run = b.addRunArtifact(suite.compile);
        run.addArgs(args.items);
        break :run run;
    };
    if (suite.spawns_collo)
        run.step.dependOn(ctx.install_collo_step);
    if (suite.release_only_tests)
        enableReleaseOnlyTests(ctx, run);
    switch (skips) {
        .inherited => {},
        .strict => |gate| {
            run.setName(b.fmt("run {s} with strict skips", .{suite_root}));
            run.setEnvironmentVariable(skip_allowlist.strict_env, "1");
            run.step.dependOn(gate);
        },
    }
    return run;
}

/// Test names are paths relative to the directory of this file, which is
/// why it, and nothing chosen by hand, scopes the allowlist's entries.
fn suiteRoot(compile: *std.Build.Step.Compile) []const u8 {
    const root = compile.root_module.root_source_file orelse
        @panic("a runner suite has no root source file");
    return switch (root) {
        .src_path => |source| source.sub_path,
        else => @panic("a runner suite's root must be a file in this repository"),
    };
}

/// A step outside `zig build --list` that only orders others.
fn addHiddenStep(b: *std.Build, name: []const u8) *std.Build.Step {
    const step = b.allocator.create(std.Build.Step) catch @panic("OOM");
    step.* = std.Build.Step.init(.{ .id = .custom, .name = name, .owner = b });
    return step;
}

// Shared test fixtures as named modules: cross-tree test imports become
// module imports, so suite roots stop escaping their module dirs (Zig 0.15
// module-path tightening — the old relative imports made zygote-integration
// uncompilable). One instance each; every consumer suite shares the same
// module for type identity.
const TestFixtureModules = struct {
    /// collo_test_net — local-address fixture (support/net/local_address.zig).
    /// Two flavored instances, mirroring the jsc/h2_stub module-graph split:
    /// the fixture imports collo_network, which each graph builds, and a
    /// compilation must never contain both flavors of a graph's module (same
    /// source files under two module identities is a hard error since Zig
    /// 0.15).
    test_net_jsc: *std.Build.Module,
    test_net_stub: *std.Build.Module,
    /// collo_test_harness — worker runtime harness (support/worker/runtime_harness.zig).
    test_harness: *std.Build.Module,
    /// collo_worker_test_support — worker API fixtures (support/worker/api.zig).
    worker_test_support: *std.Build.Module,
    /// supervisor_fixture — worker-supervision fixture (server/tests/support/).
    /// Flavored like collo_test_net: it imports collo_server_supervisor, whose
    /// graph reaches the bindings module, so the jsc and stub flavors must stay
    /// separate compilations.
    supervisor_fixture_jsc: *std.Build.Module,
    supervisor_fixture_stub: *std.Build.Module,
    /// collo_test_tls_shim — the test TLS shim's Zig declarations
    /// (support/tls/shim.zig). It imports nothing, so both flavors share one
    /// instance.
    tls_test_shim: *std.Build.Module,
};

fn createTestNetModule(
    b: *std.Build,
    ctx: *const context_mod.Context,
    set: *const modules_mod.ModuleSet,
) *std.Build.Module {
    const test_net_module = b.createModule(.{
        .root_source_file = b.path("runtime/tests/support/net/local_address.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    // The fixture reads only the address classes and returns plain strings.
    set.importInto(test_net_module, &.{.network});
    return test_net_module;
}

fn createSupervisorFixtureModule(
    b: *std.Build,
    ctx: *const context_mod.Context,
    set: *const modules_mod.ModuleSet,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("runtime/src/server/tests/support/supervisor_fixture.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    set.importInto(module, &.{
        .server_supervisor, .server_config, .server_routes, .server_analytics,
        .server_lifecycle,  .worker_state,  .zygote,        .ipc,
        .os,                .host,
    });
    return module;
}

fn createTestFixtureModules(b: *std.Build, ctx: *const context_mod.Context) TestFixtureModules {
    const test_net_jsc = createTestNetModule(b, ctx, &ctx.jsc_set);
    const test_net_stub = createTestNetModule(b, ctx, &ctx.stub_set);

    const worker_test_support_module = b.createModule(.{
        .root_source_file = b.path("runtime/tests/support/worker/api.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    worker_test_support_module.addImport("collo_worker", ctx.jsc_set.get(.worker));
    ctx.jsc_set.importInto(worker_test_support_module, &.{
        .bindings, .worker_state, .ipc,         .os,             .cgroup,
        .http,     .common_io,    .egress_core, .worker_request,
    });

    const test_harness_module = b.createModule(.{
        .root_source_file = b.path("runtime/tests/support/worker/runtime_harness.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    test_harness_module.addImport("collo_worker", ctx.jsc_set.get(.worker));
    ctx.jsc_set.importInto(test_harness_module, &.{
        .ipc,          .os,   .http,    .egress_client, .egress_gateway,
        .worker_state, .host, .network,
    });
    test_harness_module.addImport("collo_worker_test_support", worker_test_support_module);
    test_harness_module.addImport("collo_test_net", test_net_jsc);

    return .{
        .test_net_jsc = test_net_jsc,
        .test_net_stub = test_net_stub,
        .test_harness = test_harness_module,
        .worker_test_support = worker_test_support_module,
        .supervisor_fixture_jsc = createSupervisorFixtureModule(b, ctx, &ctx.jsc_set),
        .supervisor_fixture_stub = createSupervisorFixtureModule(b, ctx, &ctx.stub_set),
        .tls_test_shim = shims.tlsTestShimModule(b, ctx.opts.target, ctx.opts.optimize),
    };
}

/// The runner every suite outside the bindings smokes is built with.
pub fn useCustomRunner(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.test_runner = .{
        .path = b.path("runtime/tests/support/test_runner.zig"),
        .mode = .simple,
    };
}

fn addJscTest(
    b: *std.Build,
    ctx: *const context_mod.Context,
    root_source: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    const compile = b.addTest(.{
        .root_module = module,
        .emit_object = true,
    });
    // The JSC-linked lanes (all, zygote-integration, local-e2e) run as raw
    // Run steps over the linked binary, and the runner accepts
    // --filter/--assert-partition at RUNTIME — the step-configured args, then
    // CLI args forwarded by runLinkedExecutable behind a `--forwarded`
    // separator (`zig build <step> -- --filter=X`). Forwarded filters NARROW
    // the step's configured domain (configured AND user, OR within each set);
    // forwarded --assert-partition is rejected. `.simple` keeps the run steps
    // plain (no --listen).
    useCustomRunner(b, compile);
    if (ctx.opts.sanitizer.instrumentsZig())
        shims.sanitizeZigModule(compile.root_module);
    shims.configureBindingsTestObject(compile, ctx.libc_file);
    shims.configureBoringSslShim(b, compile, ctx.toolchain, ctx.boringssl.headers(), ctx.opts.sanitizer);
    return compile;
}

/// The aggregate binary, compiled once from `runtime/all_tests.zig` and
/// linked once; every domain step and both GC stress profiles run it.
const MainSuite = struct {
    compile: *std.Build.Step.Compile,
    linked: link_mod.LinkedArtifact,
};

fn addMainSuite(
    b: *std.Build,
    ctx: *const context_mod.Context,
    aggregate: Aggregate,
    fixtures: TestFixtureModules,
) MainSuite {
    const bench_common_module = b.createModule(.{
        .root_source_file = b.path("runtime/bench/common.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    const buildtool_module = b.createModule(.{
        .root_source_file = b.path("runtime/build/buildtool.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    const build_shims_module = b.createModule(.{
        .root_source_file = b.path("runtime/build/shims.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    const validate_webapi_module = b.createModule(.{
        .root_source_file = b.path("runtime/build/validate_webapi_tool.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
    });
    const buildtool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/build/tests/all.zig"),
            .target = ctx.opts.target,
            .optimize = ctx.opts.optimize,
            .link_libc = true,
            .link_libcpp = false,
        }),
    });
    useCustomRunner(b, buildtool_tests);
    buildtool_tests.root_module.addImport("collo_buildtool", buildtool_module);
    buildtool_tests.root_module.addImport("collo_build_shims", build_shims_module);
    buildtool_tests.root_module.addImport("collo_validate_webapi", validate_webapi_module);
    ctx.check_step.dependOn(&buildtool_tests.step);
    const buildtool_run = aggregate.addRun(b, ctx, .{ .compile = buildtool_tests });
    b.step("buildtool-test", "Run JSC-free build-tool contract tests")
        .dependOn(&buildtool_run.step);

    // Root at runtime/ so it can path-import BOTH the root-local suites
    // (runtime/tests/...) and the module-scoped suites
    // (runtime/src/<module>/tests/...): Zig collects test declarations only
    // from the ROOT module of a test compilation — a named-module import
    // (`_ = @import("zygote")`) links the module but contributes no tests.
    // The custom runner (set in addJscTest) accepts --filter/--assert-partition
    // at RUNTIME, which is what makes the per-domain steps below free — N run
    // steps over ONE compiled+linked binary.
    const benchmark_memory = b.createModule(.{
        .root_source_file = b.path("runtime/bench/sandbox/memory.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
    });
    const benchmark_timing = b.createModule(.{
        .root_source_file = b.path("runtime/bench/sandbox/timing.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
    });
    const benchmark_protocol = b.createModule(.{
        .root_source_file = b.path("runtime/bench/sandbox/protocol.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
    });
    const benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/tests/contracts/benchmark_all.zig"),
            .target = ctx.opts.target,
            .optimize = ctx.opts.optimize,
            .link_libc = true,
        }),
    });
    useCustomRunner(b, benchmark_tests);
    benchmark_tests.root_module.addImport("benchmark_memory", benchmark_memory);
    benchmark_tests.root_module.addImport("benchmark_timing", benchmark_timing);
    benchmark_tests.root_module.addImport("benchmark_protocol", benchmark_protocol);
    benchmark_tests.root_module.addImport("collo_bench_common", bench_common_module);
    // `benchmark_config.zig` parses what the daemon writes with the server's parser.
    ctx.stub_set.importInto(benchmark_tests.root_module, &.{.server_config});
    ctx.check_step.dependOn(&benchmark_tests.step);
    const benchmark_run = aggregate.addRun(b, ctx, .{ .compile = benchmark_tests });
    b.step("microbench-test", "Test benchmark measurement parsers and timestamp arithmetic")
        .dependOn(&benchmark_run.step);

    const all_tests = addJscTest(b, ctx, "runtime/all_tests.zig");
    all_tests.root_module.addImport("benchmark_memory", benchmark_memory);
    all_tests.root_module.addImport("benchmark_timing", benchmark_timing);
    all_tests.root_module.addImport("benchmark_protocol", benchmark_protocol);
    ctx.check_step.dependOn(&all_tests.step);
    shims.configureBoringSslTestShim(b, all_tests, ctx.toolchain, ctx.opts.sanitizer);
    shims.configureSecretBytesTestShim(b, all_tests, ctx.toolchain, ctx.opts.sanitizer);
    shims.configureHpackShim(b, all_tests, ctx.patched_ls_hpack);
    all_tests.root_module.addImport("bindings_support", ctx.bindings_support_module);
    all_tests.root_module.addImport("zygote_support", ctx.zygote_support_module);
    // The installed `collo`, which the gateway suite spawns as a real gateway.
    all_tests.root_module.addImport("collo_process_options", ctx.process_options_module);
    all_tests.root_module.addImport("collo_bench_common", bench_common_module);
    all_tests.root_module.addImport("collo_buildtool", buildtool_module);
    all_tests.root_module.addImport("collo_build_shims", build_shims_module);
    all_tests.root_module.addImport("collo_validate_webapi", validate_webapi_module);
    all_tests.root_module.addImport("collo_worker_test_support", fixtures.worker_test_support);
    // The comment provenance gate in conventions.zig counts markers with the
    // same matcher as the `provenance-baseline` step.
    all_tests.root_module.addImport("collo_comments", b.createModule(.{
        .root_source_file = b.path("dev/comments/root.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
    }));
    // Every suite file — root-local under runtime/tests/ and module-scoped
    // under runtime/src/<module>/tests/ — is a path import of the ROOT module
    // (test collection is root-module-only), so all of them resolve the
    // fixture and production modules through this one import table.
    all_tests.root_module.addImport("collo_test_harness", fixtures.test_harness);
    all_tests.root_module.addImport("collo_test_net", fixtures.test_net_jsc);
    all_tests.root_module.addImport("supervisor_fixture", fixtures.supervisor_fixture_jsc);
    all_tests.root_module.addImport("collo_test_tls_shim", fixtures.tls_test_shim);
    ctx.jsc_set.importInto(all_tests.root_module, &.{
        .bindings,          .ipc,              .dns_name,      .network,
        .os,                .cgroup,           .ktls,          .http,
        .hpack,             .common_io,        .io_uring_tags, .worker_state,
        .worker,            .worker_request,   .egress_client, .egress_transport,
        .egress_gateway,    .boringssl,        .server_main,   .server_gateway,
        .server_supervisor, .server_lifecycle, .zygote,        .limits,
        .host,              .server_analytics, .server_config, .server_routes,
    });

    const linked_all = link_mod.addJscLink(b, ctx.link_ctx, .{
        .name = "all",
        .object = all_tests,
        .bridge = ctx.bridge,
        .sanitizer = ctx.opts.sanitizer,
    });

    var partition_args: std.ArrayList([]const u8) = .empty;
    for (domain_steps) |domain| {
        for (domain.filters) |prefix|
            partition_args.append(b.allocator, b.fmt("--assert-partition={s}", .{prefix})) catch @panic("OOM");
    }
    _ = aggregate.addRun(b, ctx, .{
        .compile = all_tests,
        .linked = linked_all,
        .configured_args = partition_args.items,
        .spawns_collo = true,
        .release_only_tests = true,
    });

    for (domain_steps) |domain| {
        const run = addRunnerRun(b, ctx, .{
            .compile = all_tests,
            .linked = linked_all,
            .configured_args = filterArgs(b, domain.filters),
            .spawns_collo = true,
            .release_only_tests = true,
        }, .inherited);
        b.step(domain.step_name, domain.description).dependOn(&run.step);
    }
    return .{ .compile = all_tests, .linked = linked_all };
}

/// `--filter=<prefix>` for each prefix, in order.
fn filterArgs(b: *std.Build, prefixes: []const []const u8) []const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    for (prefixes) |prefix|
        args.append(b.allocator, b.fmt("--filter={s}", .{prefix})) catch @panic("OOM");
    return args.items;
}

/// One engine profile of `bindings-gc-stress`. JSC applies its `JSC_<option>`
/// environment variables before Collo's options callback runs
/// (`Options::initializeWithOptionsCustomization`), and that callback sets no
/// collector debugging option, so the profile needs no bridge code. Production
/// never sees these variables: the server spawns the zygote with a canonical
/// environment (`worker_environment_retained_names` in
/// `runtime/src/zygote/host_client.zig`), and so does every test that forks a
/// worker from the installed `collo`.
const GcStressProfile = struct {
    name: []const u8,
    environment: []const EnvironmentVariable,
    /// The tests the profile runs, as runner prefixes.
    filters: []const []const u8,
};

const EnvironmentVariable = struct { name: []const u8, value: []const u8 };

/// The window tests and churn workloads of the bindings, under
/// `runtime/src/bindings/tests/gc_stress/`.
const gc_stress_filter = "src.bindings.tests.gc_stress.";

const gc_stress_profiles = [_]GcStressProfile{
    .{
        // A synchronous full collection each time a size-class allocator
        // takes its slow path (`LocalAllocator::doTestCollectionsIfNeeded`;
        // a precise allocation past `MarkedSpace::largeCutoff` never does),
        // swept at once with freed cells scribbled: a cell left unrooted
        // across script or allocation dies inside the window that holds it.
        // Deterministic when the test allocates a cell inside that window.
        .name = "forced",
        .environment = &.{
            .{ .name = "JSC_slowPathAllocsBetweenGCs", .value = "1" },
            .{ .name = "JSC_sweepSynchronously", .value = "true" },
            .{ .name = "JSC_scribbleFreeCells", .value = "true" },
            .{ .name = "JSC_verifyGC", .value = "true" },
        },
        .filters = &.{gc_stress_filter},
    },
    .{
        // Back-to-back concurrent collections on a thread of their own, each
        // followed by a stop-the-world re-mark from the roots that aborts on a
        // live cell the cycle left unmarked (`Heap::verifyGC`): a missed write
        // barrier or a container changed without the cell lock. Evidence, not
        // proof, since the marker must visit the owner inside a window a few
        // instructions wide. The promise and body-stream rooting tests add
        // young collections between a cell's stores and its barriers, and the
        // WebAPI suites the churn of every stream, event, port and timeline
        // they drive.
        .name = "concurrent",
        .environment = &.{
            .{ .name = "JSC_collectContinuously", .value = "true" },
            .{ .name = "JSC_verifyGC", .value = "true" },
            .{ .name = "JSC_scribbleFreeCells", .value = "true" },
        },
        .filters = &.{
            gc_stress_filter,
            "src.bindings.tests.stream_promise_roots.",
            "src.bindings.tests.body_stream_roots.",
            "tests.webapi.",
        },
    },
};

/// The strict runs of both GC stress profiles, one after the other, between
/// two hidden steps smoke.zig orders against its other lanes.
pub const StrictGcStress = struct {
    /// Every strict run waits on it.
    start: *std.Build.Step,
    /// Completes when both strict runs pass.
    done: *std.Build.Step,
};

/// `bindings-gc-stress`: both profiles over the aggregate binary already
/// linked, one run each, the second after the first so their collector
/// threads never share the machine. Each profile is sized to finish in about
/// two minutes on the reference machine, and one that outgrows that narrows
/// its filters rather than leaving smoke.
fn addGcStressLane(
    b: *std.Build,
    ctx: *const context_mod.Context,
    main_suite: MainSuite,
    strict_gate: *std.Build.Step,
) StrictGcStress {
    const lane = b.step(
        "bindings-gc-stress",
        "Run the bindings' GC window tests and churn workloads under the forced and concurrent collector profiles",
    );
    const strict: StrictGcStress = .{
        .start = addHiddenStep(b, "bindings-gc-stress with strict skips: start"),
        .done = addHiddenStep(b, "bindings-gc-stress with strict skips"),
    };
    var previous_run: ?*std.Build.Step.Run = null;
    var previous_strict_run: ?*std.Build.Step.Run = null;
    for (gc_stress_profiles) |profile| {
        const suite: RunnerSuite = .{
            .compile = main_suite.compile,
            .linked = main_suite.linked,
            .configured_args = filterArgs(b, profile.filters),
            .spawns_collo = true,
        };
        const run = addRunnerRun(b, ctx, suite, .inherited);
        applyGcStressProfile(b, run, profile, "");
        if (previous_run) |previous| run.step.dependOn(&previous.step);
        lane.dependOn(&run.step);
        previous_run = run;

        const strict_run = addRunnerRun(b, ctx, suite, .{ .strict = strict_gate });
        applyGcStressProfile(b, strict_run, profile, " with strict skips");
        strict_run.step.dependOn(strict.start);
        if (previous_strict_run) |previous| strict_run.step.dependOn(&previous.step);
        strict.done.dependOn(&strict_run.step);
        previous_strict_run = strict_run;
    }
    return strict;
}

fn applyGcStressProfile(
    b: *std.Build,
    run: *std.Build.Step.Run,
    profile: GcStressProfile,
    comptime name_suffix: []const u8,
) void {
    run.setName(b.fmt("run the {s} GC stress profile" ++ name_suffix, .{profile.name}));
    for (profile.environment) |variable|
        run.setEnvironmentVariable(variable.name, variable.value);
}

/// Tests that tear down a terminated VM trip a JSC debug-build assertion, so
/// they run only against a Release JSC; the build knows the profile, so the
/// gate is decided here instead of by whoever remembers to set the variable.
fn enableReleaseOnlyTests(ctx: *const context_mod.Context, run: *std.Build.Step.Run) void {
    if (std.mem.eql(u8, ctx.jsc.cmake_build_type, "Release"))
        run.setEnvironmentVariable("COLLO_VM_TERMINATION_RELEASE_LANE", "1");
}

// Domain partition of the `all` suite. Test names are file paths relative to
// runtime/, the directory of the root runtime/all_tests.zig, with `/` read as
// `.` plus `.test.`, so these prefixes are the tree layout:
// `src.<module>.tests.*` for module-scoped suites,
// `build.tests.*` for the build-tool suite, `tests.*` for root-local ones.
// Step NAMES are the stable API; only the filter strings track the layout.
// The aggregate's --assert-partition fails on any test outside every prefix
// AND on any prefix matching zero tests (a domain lost from the aggregate);
// a domain step's filter matching zero tests fails too — the table cannot
// silently drift from the tree in either direction.
const DomainStep = struct {
    step_name: []const u8,
    description: []const u8,
    filters: []const []const u8,
};

const domain_steps = [_]DomainStep{
    .{ .step_name = "bindings-test", .description = "Run the JSC bindings domain", .filters = &.{"src.bindings.tests."} },
    .{ .step_name = "common-test", .description = "Run the common (ipc/os/http/...) domain", .filters = &.{"src.common.tests."} },
    .{ .step_name = "server-analytics-test", .description = "Run the server analytics sink domain", .filters = &.{"src.server.tests.analytics."} },
    .{ .step_name = "server-ingress-test", .description = "Run the server ingress domain", .filters = &.{"src.server.tests.ingress."} },
    .{ .step_name = "server-routes-test", .description = "Run the configuration and route table domain", .filters = &.{ "src.server.tests.config.", "src.server.tests.routes." } },
    .{ .step_name = "server-supervisor-test", .description = "Run the server worker-supervision domain", .filters = &.{"src.server.tests.supervisor."} },
    .{ .step_name = "server-gateway-test", .description = "Run the server's side of the egress gateway", .filters = &.{"src.server.tests.gateway."} },
    .{ .step_name = "server-core-test", .description = "Run server net/tls/lifecycle/boot", .filters = &.{ "src.server.tests.net.", "src.server.tests.tls.", "src.server.tests.lifecycle.", "src.server.tests.boot." } },
    .{ .step_name = "worker-test", .description = "Run the worker runtime/scheduler domain", .filters = &.{"src.worker.tests."} },
    .{ .step_name = "egress-test", .description = "Run the egress client domain", .filters = &.{ "src.egress.tests.core.", "src.egress.tests.client." } },
    .{ .step_name = "egress-gateway-test", .description = "Run the egress gateway process domain", .filters = &.{"src.egress.tests.gateway."} },
    .{ .step_name = "zygote-test", .description = "Run the zygote domain", .filters = &.{"src.zygote.tests."} },
    .{ .step_name = "host-test", .description = "Run the host (launch/cgroup/dispatch) domain", .filters = &.{"src.host.tests."} },
    .{ .step_name = "meta-test", .description = "Run conventions/buildtool/contracts/test-runner self-tests", .filters = &.{ "tests.conventions.", "build.tests.", "tests.contracts.", "tests.support." } },
    .{ .step_name = "webapi-test", .description = "Run the WebAPI compatibility suites, in process and in a forked worker", .filters = &.{"tests.webapi."} },
};

/// The server's gateway control client and the control wire, without JSC.
/// The client's own file is the module root, so the compilation holds the
/// client and the wire it reaches through `collo_egress_gateway`, and none of
/// the server.
fn addGatewayControlSuite(
    b: *std.Build,
    ctx: *const context_mod.Context,
    aggregate: Aggregate,
) void {
    const control_client_module = b.createModule(.{
        .root_source_file = b.path("runtime/src/server/gateway/control_client.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    ctx.stub_set.importInto(control_client_module, &.{ .ipc, .os, .egress_gateway });

    const control_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/src/server/tests/gateway/control_plane.zig"),
            .target = ctx.opts.target,
            .optimize = ctx.opts.optimize,
            .link_libc = true,
            .link_libcpp = false,
        }),
    });
    useCustomRunner(b, control_tests);
    ctx.stub_set.importInto(control_tests.root_module, &.{ .ipc, .os });
    control_tests.root_module.addImport(
        "collo_server_gateway_control_client",
        control_client_module,
    );
    // The gateway module's graph reaches the egress decoders.
    codecs_mod.linkInto(control_tests, ctx.codecs);
    const run = aggregate.addRun(b, ctx, .{ .compile = control_tests });
    b.step(
        "server-gateway-control-test",
        "Run JSC-free tests of the server's egress gateway control client",
    ).dependOn(&run.step);
}

fn bridgeLibraries(b: *std.Build, ctx: *const context_mod.Context) shims.BridgeLibraries {
    return .{ .icu = ctx.link_ctx.icu.headers(b), .boringssl = ctx.boringssl.headers(), .codecs = ctx.codecs };
}

fn addSanitizedSmoke(b: *std.Build, ctx: *const context_mod.Context) void {
    const sanitizer = shims.BindingsSanitizer{ .mode = .address_leak };
    const smoke_module = b.createModule(.{
        .root_source_file = b.path("runtime/src/bindings/tests/smoke.zig"),
        .target = ctx.opts.target,
        .optimize = .Debug,
        .link_libc = true,
        .link_libcpp = false,
    });
    shims.sanitizeZigModule(smoke_module);
    smoke_module.addImport("bindings_support", ctx.bindings_support_module);

    const sanitized_bridge_module = b.createModule(.{
        .target = ctx.opts.target,
        .optimize = .Debug,
        .link_libcpp = false,
        .sanitize_c = .off,
    });
    shims.sanitizeZigModule(sanitized_bridge_module);
    const sanitized_bridge = b.addLibrary(.{
        .name = "collo_jsc_bindings_asan",
        .root_module = sanitized_bridge_module,
        .use_lld = false,
    });
    if (ctx.jsc.step) |step|
        sanitized_bridge.step.dependOn(&step.step);
    shims.configureBridgeLibrary(
        b,
        sanitized_bridge,
        ctx.libc_file,
        ctx.toolchain,
        ctx.jsc.cmake_build_type,
        ctx.jsc.build_dir,
        ctx.jsc.webkit_source_dir,
        bridgeLibraries(b, ctx),
        sanitizer,
    );

    const smoke_tests = b.addTest(.{
        .root_module = smoke_module,
        .emit_object = true,
    });
    shims.configureBindingsTestObject(smoke_tests, ctx.libc_file);
    shims.configureBoringSslShim(b, smoke_tests, ctx.toolchain, ctx.boringssl.headers(), sanitizer);

    const run = link_mod.addBindingsTestRunner(b, ctx.link_ctx, .{
        .name = "bindings-smoke-asan",
        .object = smoke_tests,
        .bridge = sanitized_bridge,
        .sanitizer = sanitizer,
    });
    b.step(
        "test-bindings-sanitized",
        "Run the small JSC bindings smoke suite under ASan/LSan",
    ).dependOn(&run.step);
}

fn addValgrindSmoke(b: *std.Build, ctx: *const context_mod.Context) void {
    const smoke_module = b.createModule(.{
        .root_source_file = b.path("runtime/src/bindings/tests/smoke.zig"),
        .target = ctx.opts.target,
        .optimize = .Debug,
        .link_libc = true,
        .link_libcpp = false,
        .valgrind = true,
    });
    smoke_module.addImport("bindings_support", ctx.bindings_support_module);

    const valgrind_bridge_module = b.createModule(.{
        .target = ctx.opts.target,
        .optimize = .Debug,
        .link_libcpp = false,
        .sanitize_c = .off,
        .valgrind = true,
    });
    const valgrind_bridge = b.addLibrary(.{
        .name = "collo_jsc_bindings_valgrind",
        .root_module = valgrind_bridge_module,
        .use_lld = false,
    });
    if (ctx.jsc.step) |step|
        valgrind_bridge.step.dependOn(&step.step);
    shims.configureBridgeLibrary(
        b,
        valgrind_bridge,
        ctx.libc_file,
        ctx.toolchain,
        ctx.jsc.cmake_build_type,
        ctx.jsc.build_dir,
        ctx.jsc.webkit_source_dir,
        bridgeLibraries(b, ctx),
        .{},
    );

    const smoke_tests = b.addTest(.{
        .root_module = smoke_module,
        .emit_object = true,
    });
    shims.configureBindingsTestObject(smoke_tests, ctx.libc_file);
    shims.configureBoringSslShim(b, smoke_tests, ctx.toolchain, ctx.boringssl.headers(), .{});

    const run = link_mod.addBindingsValgrindRunner(b, ctx.link_ctx, .{
        .name = "bindings-smoke-valgrind",
        .object = smoke_tests,
        .bridge = valgrind_bridge,
    });
    b.step(
        "test-bindings-valgrind",
        "Run the small JSC bindings smoke suite under Valgrind/Memcheck",
    ).dependOn(&run.step);
}

/// Registers the lane and returns its strict run for smoke.zig to order.
fn addZygoteIntegration(
    b: *std.Build,
    ctx: *const context_mod.Context,
    test_harness_module: *std.Build.Module,
    strict_gate: *std.Build.Step,
) *std.Build.Step.Run {
    const integration_tests = addJscTest(b, ctx, "runtime/tests/integration/zygote.zig");
    ctx.check_step.dependOn(&integration_tests.step);
    shims.configureBoringSslTestShim(b, integration_tests, ctx.toolchain, ctx.opts.sanitizer);
    shims.configureHpackShim(b, integration_tests, ctx.patched_ls_hpack);
    integration_tests.root_module.addImport("zygote_support", ctx.zygote_support_module);
    integration_tests.root_module.addImport("collo_test_harness", test_harness_module);
    // `.limits` holds the worker limits the tests size their launches and
    // waits by (`limits.worker`, `limits.process`).
    ctx.jsc_set.importInto(integration_tests.root_module, &.{ .os, .host, .limits });

    const suite: RunnerSuite = .{
        .compile = integration_tests,
        .linked = link_mod.addJscLink(b, ctx.link_ctx, .{
            .name = "zygote-integration",
            .object = integration_tests,
            .bridge = ctx.bridge,
            .sanitizer = ctx.opts.sanitizer,
        }),
        .spawns_collo = true,
    };
    const run = addRunnerRun(b, ctx, suite, .inherited);
    b.step("zygote-integration", "Run zygote/cgroup integration tests").dependOn(&run.step);
    return addRunnerRun(b, ctx, suite, .{ .strict = strict_gate });
}

/// Registers the lane and returns its strict run for smoke.zig to order.
fn addLocalE2e(
    b: *std.Build,
    ctx: *const context_mod.Context,
    test_harness_module: *std.Build.Module,
    tls_test_shim_module: *std.Build.Module,
    strict_gate: *std.Build.Step,
) *std.Build.Step.Run {
    const e2e_tests = addJscTest(b, ctx, "runtime/tests/integration/all.zig");
    ctx.check_step.dependOn(&e2e_tests.step);
    shims.configureBoringSslTestShim(b, e2e_tests, ctx.toolchain, ctx.opts.sanitizer);
    shims.configureHpackShim(b, e2e_tests, ctx.patched_ls_hpack);
    e2e_tests.root_module.addImport("collo_test_harness", test_harness_module);
    e2e_tests.root_module.addImport("collo_test_tls_shim", tls_test_shim_module);
    const local_server_options = b.addOptions();
    local_server_options.addOption([]const u8, "egress_gateway_executable_path", b.getInstallPath(.bin, "collo"));
    e2e_tests.root_module.addImport("local_server_options", local_server_options.createModule());
    e2e_tests.root_module.addImport("zygote_support", ctx.zygote_support_module);
    // `.network` writes the denial texts the network tests expect, with the
    // function the gateway and the worker write them with.
    ctx.jsc_set.importInto(e2e_tests.root_module, &.{
        .worker,           .server_main, .server_supervisor, .server_config, .server_routes,
        .server_lifecycle, .os,          .http,              .hpack,         .ipc,
        .worker_state,     .host,        .egress_gateway,    .network,       .limits,
    });

    const suite: RunnerSuite = .{
        .compile = e2e_tests,
        .linked = link_mod.addJscLink(b, ctx.link_ctx, .{
            .name = "local-e2e",
            .object = e2e_tests,
            .bridge = ctx.bridge,
            .sanitizer = ctx.opts.sanitizer,
        }),
        .spawns_collo = true,
    };
    const run = addRunnerRun(b, ctx, suite, .inherited);
    b.step("local-e2e", "Run local full-flow server/worker e2e tests").dependOn(&run.step);
    return addRunnerRun(b, ctx, suite, .{ .strict = strict_gate });
}

const StubSuite = struct {
    name: []const u8,
    root: []const u8,
    /// Per-domain fast lane this suite's run step feeds (<domain>-fast-test).
    domain: Domain,
    libc: bool = true,
    libcpp: bool = false,
    imports: []const ModuleId = &.{},
    hpack: bool = false,
    boringssl_shim: bool = false,
    tls_test_shim: bool = false,
    boringssl_archives: bool = false,

    const Domain = enum { common, server, worker, egress };
};

const stub_suites = [_]StubSuite{
    .{
        .name = "common-http",
        .domain = .common,
        .root = "runtime/src/common/tests/http.zig",
        .libc = false,
        .imports = &.{ .http, .hpack },
        .hpack = true,
    },
    .{
        // The rules of the network setting are data in and data out.
        .name = "common-network",
        .domain = .common,
        .root = "runtime/src/common/tests/network/all.zig",
        .libc = false,
        .imports = &.{ .network, .dns_name },
    },
    .{
        .name = "h2-request",
        .domain = .server,
        .root = "runtime/src/server/tests/http2/request.zig",
        .imports = &.{ .server_h2, .ipc },
        .hpack = true,
    },
    .{
        .name = "h2-connection",
        .domain = .server,
        .root = "runtime/src/server/tests/http2/connection.zig",
        .imports = &.{ .server_h2, .http, .hpack, .ipc, .os, .limits },
        .hpack = true,
    },
    .{
        .name = "h2-frame-reader",
        .domain = .server,
        .root = "runtime/src/server/tests/http2/frame_reader.zig",
        .imports = &.{ .server_h2, .http, .limits },
        .hpack = true,
    },
    .{
        .name = "ipc",
        .domain = .common,
        .root = "runtime/src/common/tests/ipc.zig",
        .imports = &.{ .ipc, .os, .worker_state },
    },
    .{
        .name = "worker-request-transport",
        .domain = .worker,
        .root = "runtime/src/worker/tests/request/transport.zig",
        .imports = &.{ .worker_request, .ipc },
    },
    .{
        // The sink, console lines and access records are plain data and file
        // writes, with no engine behind them.
        .name = "server-analytics",
        .domain = .server,
        .root = "runtime/src/server/tests/analytics/all.zig",
        .imports = &.{ .server_analytics, .limits, .worker_state },
    },
    .{
        // Parsing and validating a configuration is text in, data out.
        .name = "server-config",
        .domain = .server,
        .root = "runtime/src/server/tests/config/all.zig",
        .imports = &.{ .server_config, .limits, .network },
    },
    .{
        // The route table is a pure lookup, and the artifacts and the network
        // policy image are bytes sealed into memfds; no engine runs.
        .name = "server-routes",
        .domain = .server,
        .root = "runtime/src/server/tests/routes/all.zig",
        .imports = &.{ .server_routes, .server_config, .limits, .ipc, .os, .network },
    },
    .{
        // Worker supervision is the pools, the launcher and the reaper over
        // them, usage records and their exactly-once index: no JavaScript
        // runs here, so the lane that pays for an engine is the wrong home
        // for it. The JSC-linked aggregate still collects the same tests;
        // this entry makes them runnable without a WebKit build.
        .name = "server-supervisor",
        .domain = .server,
        .root = "runtime/src/server/tests/supervisor/all.zig",
        .imports = &.{
            .server_supervisor, .server_config,  .server_routes, .server_analytics,
            .zygote,            .worker_state,   .ipc,           .os,
            .server_lifecycle,  .cgroup,         .limits,        .io_uring_tags,
            .host,              .egress_gateway,
        },
    },
    .{
        .name = "egress-http2",
        .domain = .egress,
        .root = "runtime/src/egress/tests/client/http2/all.zig",
        .imports = &.{ .egress_client, .egress_http2, .http, .hpack },
        .hpack = true,
    },
    .{
        .name = "egress-tls",
        .domain = .egress,
        .root = "runtime/src/egress/tests/client/tls.zig",
        .libcpp = true,
        .imports = &.{ .egress_client, .egress_tls, .boringssl },
        .boringssl_shim = true,
        .tls_test_shim = true,
        .boringssl_archives = true,
    },
    .{
        // http1/support.zig gets its shared client fixture via the
        // collo_test_net module (wired into every stub suite below).
        .name = "egress-http1",
        .domain = .egress,
        .root = "runtime/src/egress/tests/client/http1.zig",
        .libcpp = true,
        .imports = &.{ .egress_client, .egress_transport },
        .hpack = true,
        .boringssl_shim = true,
        .boringssl_archives = true,
    },
    .{
        .name = "egress-core",
        .domain = .egress,
        .root = "runtime/src/egress/tests/core/all.zig",
        .libcpp = true,
        .imports = &.{ .egress_client, .bindings, .egress_core, .egress_transport, .limits },
        .hpack = true,
        .boringssl_shim = true,
        .boringssl_archives = true,
    },
    .{
        .name = "egress-data-io",
        .domain = .egress,
        .root = "runtime/src/egress/tests/client/data_io.zig",
        .libcpp = true,
        .imports = &.{
            .egress_client, .egress_data_io, .egress_accounting, .common_io,
            .egress_io,     .io_uring_tags,  .os,                .http,
            .hpack,         .boringssl,
        },
        .hpack = true,
        .boringssl_shim = true,
        .boringssl_archives = true,
    },
    .{
        // pool/support.zig gets its shared client fixture via the
        // collo_test_net module (wired into every stub suite below).
        .name = "egress-pool",
        .domain = .egress,
        .root = "runtime/src/egress/tests/client/pool.zig",
        .libcpp = true,
        .imports = &.{ .egress_client, .egress_pool },
        .hpack = true,
        .boringssl_shim = true,
        .tls_test_shim = true,
        .boringssl_archives = true,
    },
};

fn addH2TransportSuites(
    b: *std.Build,
    ctx: *const context_mod.Context,
    aggregate: Aggregate,
    fixtures: TestFixtureModules,
) void {
    const h2_step = b.step("h2-transport-test", "Run JSC-free HTTP/2 transport tests");
    // Per-domain fast lanes over the SAME run artifacts (zero duplicate
    // compiles): each lane depends on its StubSuite.domain group's run steps;
    // h2-transport-test stays the pinned umbrella over all of them.
    const fast_steps = std.enums.EnumArray(StubSuite.Domain, *std.Build.Step).init(.{
        .common = b.step("common-fast-test", "Run the common JSC-free fast lane"),
        .server = b.step("server-fast-test", "Run the server JSC-free fast lane"),
        .worker = b.step("worker-fast-test", "Run the worker JSC-free fast lane"),
        .egress = b.step("egress-fast-test", "Run the egress JSC-free fast lane"),
    });
    for (stub_suites) |suite| {
        const compile = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.root),
                .target = ctx.opts.target,
                .optimize = ctx.opts.optimize,
                .link_libc = suite.libc,
                .link_libcpp = suite.libcpp,
            }),
        });
        ctx.stub_set.importInto(compile.root_module, suite.imports);
        // The same runner the JSC-linked lanes use, so there is ONE definition
        // of what a test run may do. The stock runner counts every error log
        // and has no way for a test to say it drove one on purpose — which the
        // paths that announce lost usage records must — so a suite split
        // across two runners is a suite with two different gates, and the
        // weaker one is whichever a test happens to land in.
        useCustomRunner(b, compile);
        // Unconditional: lazy compilation makes an unreferenced fixture free,
        // so every suite sees the same import table the JSC-linked aggregate
        // offers. A suite root that had to reach these through relative paths
        // would escape its own module dir and fail to compile.
        compile.root_module.addImport("collo_test_net", fixtures.test_net_stub);
        compile.root_module.addImport("supervisor_fixture", fixtures.supervisor_fixture_stub);
        compile.root_module.addImport("collo_test_tls_shim", fixtures.tls_test_shim);
        // The fast lanes belong to the same type-check gate as everything else:
        // a suite that stops compiling must fail `check`, not wait for someone
        // to run its lane.
        ctx.check_step.dependOn(&compile.step);
        if (suite.hpack)
            shims.configureHpackShim(b, compile, ctx.patched_ls_hpack);
        if (suite.boringssl_shim)
            shims.configureBoringSslShim(b, compile, ctx.toolchain, ctx.boringssl.headers(), .{});
        if (suite.tls_test_shim)
            shims.configureBoringSslTestShim(b, compile, ctx.toolchain, .{});
        if (suite.boringssl_archives)
            ctx.boringssl.linkArchives(b, compile);
        // Most module graphs reach the egress decoders; an archive no test
        // calls into adds nothing to the executable. A suite built without
        // libc stays without it.
        if (suite.libc)
            codecs_mod.linkInto(compile, ctx.codecs);

        const run = aggregate.addRun(b, ctx, .{ .compile = compile });
        h2_step.dependOn(&run.step);
        fast_steps.get(suite.domain).dependOn(&run.step);
    }
}

/// The JSC-free suite of `wsl-config` (dev/wsl), run against temporary
/// directories shaped like a cgroup2 root, so it needs no delegated subtree.
fn addWslConfigSuite(b: *std.Build, ctx: *const context_mod.Context, aggregate: Aggregate) void {
    const wsl_config_module = b.createModule(.{
        .root_source_file = b.path("dev/wsl/cgroup_env.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
    });
    const wsl_config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("dev/wsl/tests/cgroup_env.zig"),
            .target = ctx.opts.target,
            .optimize = ctx.opts.optimize,
            .link_libc = true,
        }),
    });
    useCustomRunner(b, wsl_config_tests);
    wsl_config_tests.root_module.addImport("collo_wsl_config", wsl_config_module);
    ctx.check_step.dependOn(&wsl_config_tests.step);
    const run = aggregate.addRun(b, ctx, .{ .compile = wsl_config_tests });
    b.step("wsl-config-test", "Test wsl-config's prepare against directories shaped like a cgroup2 root (JSC-free)")
        .dependOn(&run.step);
}
