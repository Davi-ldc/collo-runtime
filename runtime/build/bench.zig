//! All bench steps. VM benches (JSC) follow the configured optimize mode;
//! the JSC-free egress benches always build ReleaseFast on a stub graph —
//! Debug numbers for the data plane are noise.
//!
//! Every bench root also reaches `check` as an object — type-check, no link,
//! no run — in the mode it really builds in. A bench is only compiled when
//! someone runs it, so without that dependency a root rots behind a green
//! gate until the next measurement needs it.
const std = @import("std");
const context_mod = @import("context.zig");
const link_mod = @import("link.zig");
const modules_mod = @import("modules.zig");
const shims = @import("shims.zig");
const toolchain_mod = @import("toolchain.zig");

/// The shared JavaScript workload corpus under `runtime/bench/workloads/`,
/// reachable from a bench root by name: naming the files here is the same
/// move the webapi bench makes for its cases, and it is what lets several
/// benches use one workload without any of them owning the copy.
const js_workload_names = [_][]const u8{
    "array_ops",       "call_vs_construct", "chacha",      "exception_paths",
    "growing_cache",   "hmac_sha256",       "intl_format", "json_roundtrip",
    "json_scan",       "many_functions",    "prelude",     "prototype_walk",
    "proxy_traps",     "regex_router",      "shape_churn", "ssr",
    "switch_dispatch", "trailer",
};

/// Wires the corpus into `module` as `workload_<name>_js`.
fn addJsWorkloadImports(b: *std.Build, module: *std.Build.Module) void {
    for (js_workload_names) |name|
        module.addAnonymousImport(b.fmt("workload_{s}_js", .{name}), .{
            .root_source_file = b.path(b.fmt("runtime/bench/workloads/{s}.js", .{name})),
        });
}

const webapi_bench_imports = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "webapi_bench_harness_js", .path = "runtime/tests/webapi/support/bench_harness.js" },
    .{ .name = "webapi_globals_bench_js", .path = "runtime/tests/webapi/globals/globals.bench.js" },
    .{ .name = "webapi_dom_exception_bench_js", .path = "runtime/tests/webapi/dom_exception/dom_exception.bench.js" },
    .{ .name = "webapi_event_bench_js", .path = "runtime/tests/webapi/event/event.bench.js" },
    .{ .name = "webapi_message_channel_bench_js", .path = "runtime/tests/webapi/message_channel/message_channel.bench.js" },
    .{ .name = "webapi_performance_bench_js", .path = "runtime/tests/webapi/performance/performance.bench.js" },
    .{ .name = "webapi_abort_bench_js", .path = "runtime/tests/webapi/abort/abort.bench.js" },
    .{ .name = "webapi_blob_bench_js", .path = "runtime/tests/webapi/blob/blob.bench.js" },
    .{ .name = "webapi_file_bench_js", .path = "runtime/tests/webapi/file/file.bench.js" },
    .{ .name = "webapi_formdata_bench_js", .path = "runtime/tests/webapi/formdata/formdata.bench.js" },
    .{ .name = "webapi_formdata_multipart_body_bench_js", .path = "runtime/tests/webapi/formdata/formdata_multipart_body.bench.js" },
    .{ .name = "webapi_crypto_bench_js", .path = "runtime/tests/webapi/crypto/crypto.bench.js" },
    .{ .name = "webapi_structured_clone_bench_js", .path = "runtime/tests/webapi/structured_clone/structured_clone.bench.js" },
    .{ .name = "webapi_report_error_bench_js", .path = "runtime/tests/webapi/report_error/report_error.bench.js" },
    .{ .name = "webapi_navigator_bench_js", .path = "runtime/tests/webapi/navigator/navigator.bench.js" },
    .{ .name = "webapi_console_bench_js", .path = "runtime/tests/webapi/console/console.bench.js" },
    .{ .name = "webapi_text_codec_bench_js", .path = "runtime/tests/webapi/text_codec/text_codec.bench.js" },
    .{ .name = "webapi_base64_bench_js", .path = "runtime/tests/webapi/base64/base64.bench.js" },
    .{ .name = "webapi_microtask_bench_js", .path = "runtime/tests/webapi/microtask/microtask.bench.js" },
    .{ .name = "webapi_url_bench_js", .path = "runtime/tests/webapi/url/url.bench.js" },
    .{ .name = "webapi_url_search_params_bench_js", .path = "runtime/tests/webapi/url/url_search_params.bench.js" },
    .{ .name = "webapi_url_pattern_bench_js", .path = "runtime/tests/webapi/url_pattern/url_pattern.bench.js" },
    .{ .name = "webapi_headers_bench_js", .path = "runtime/tests/webapi/headers/headers.bench.js" },
    .{ .name = "webapi_request_bench_js", .path = "runtime/tests/webapi/request/request.bench.js" },
    .{ .name = "webapi_response_bench_js", .path = "runtime/tests/webapi/response/response.bench.js" },
    .{ .name = "webapi_body_bench_js", .path = "runtime/tests/webapi/body/body.bench.js" },
    .{ .name = "webapi_streams_bench_js", .path = "runtime/tests/webapi/streams/streams.bench.js" },
    .{ .name = "webapi_streams_queuing_strategy_bench_js", .path = "runtime/tests/webapi/streams/queuing_strategy.bench.js" },
    .{ .name = "webapi_streams_readable_stream_from_bench_js", .path = "runtime/tests/webapi/streams/readable_stream_from.bench.js" },
    .{ .name = "webapi_fetch_args_bench_js", .path = "runtime/tests/webapi/fetch/fetch_args.bench.js" },
    .{ .name = "webapi_timers_bench_js", .path = "runtime/tests/webapi/timers/timers.bench.js" },
};

pub fn addAll(b: *std.Build, ctx: *const context_mod.Context) void {
    const bench_step = b.step("bench", "Run human-readable runtime benchmarks");
    addVmBenches(b, ctx, bench_step);
    addSandboxBench(b, ctx);
    addEgressBenches(b, ctx, bench_step);
}

fn benchOptionsModule(
    b: *std.Build,
    ctx: *const context_mod.Context,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "optimize_mode_name", @tagName(optimize));
    bench_options.addOption([]const u8, "target_arch_name", @tagName(ctx.opts.target.result.cpu.arch));
    bench_options.addOption([]const u8, "target_os_name", @tagName(ctx.opts.target.result.os.tag));
    bench_options.addOption([]const u8, "git_or_deploy_hash", ctx.git_or_deploy_hash);
    return bench_options.createModule();
}

fn addVmBenches(b: *std.Build, ctx: *const context_mod.Context, bench_step: *std.Build.Step) void {
    const bench_build_options_module = benchOptionsModule(b, ctx, ctx.opts.optimize);

    const vm_benches = [_]struct {
        file: []const u8,
        name: []const u8,
        step_name: []const u8,
        step_desc: []const u8,
    }{
        .{
            .file = "runtime/bench/host_lifecycle.zig",
            .name = "host_lifecycle",
            .step_name = "bench-host",
            .step_desc = "Run host-only lifecycle diagnostic (excludes ingress and gateway)",
        },
        .{
            .file = "runtime/bench/webapi.zig",
            .name = "webapi",
            .step_name = "bench-webapi",
            .step_desc = "Compare WebAPI microbenchmarks against Bun",
        },
        .{
            .file = "runtime/bench/zygote_cow.zig",
            .name = "zygote_cow",
            .step_name = "bench-zygote-cow",
            .step_desc = "Measure Collo zygote WebAPI copy-on-write memory",
        },
    };

    for (vm_benches) |bench| {
        const bench_module = b.createModule(.{
            .root_source_file = b.path(bench.file),
            .target = ctx.opts.target,
            .optimize = ctx.opts.optimize,
            .link_libc = true,
            .link_libcpp = false,
        });
        bench_module.addImport("collo_bench_build_options", bench_build_options_module);
        bench_module.addImport("collo_process_options", ctx.process_options_module);
        addJsWorkloadImports(b, bench_module);
        ctx.jsc_set.importInto(bench_module, &.{
            .zygote, .bindings,          .ipc,          .os,   .http,
            .worker, .server_supervisor, .worker_state, .host,
        });
        if (std.mem.eql(u8, bench.name, "webapi")) {
            bench_module.addImport("bindings_support", ctx.bindings_support_module);
            for (webapi_bench_imports) |entry|
                bench_module.addAnonymousImport(entry.name, .{ .root_source_file = b.path(entry.path) });
        }

        const bench_object = b.addObject(.{
            .name = bench.name,
            .root_module = bench_module,
        });
        // The VM benches already compile to an object before the link, so
        // `check` takes that very object: type-check, no link, no run.
        ctx.check_step.dependOn(&bench_object.step);
        shims.configureBindingsTestObject(bench_object, ctx.libc_file);
        shims.configureBoringSslShim(b, bench_object, ctx.toolchain, ctx.opts.sanitizer);
        shims.configureHpackShim(b, bench_object, ctx.patched_ls_hpack);

        const linked_bench = link_mod.addJscLink(b, ctx.link_ctx, .{
            .name = bench.name,
            .object = bench_object,
            .bridge = ctx.bridge,
            .sanitizer = ctx.opts.sanitizer,
        });
        const run_bench = link_mod.runLinkedExecutable(b, linked_bench, ctx.opts.sanitizer, &.{});
        if (std.mem.eql(u8, bench.name, "host_lifecycle")) {
            const install_bench = b.addInstallBinFile(linked_bench.executable, "host_lifecycle");
            b.step("install-bench-host", "Build and install the host benchmark without running it")
                .dependOn(&install_bench.step);
        }
        const single_step = b.step(bench.step_name, bench.step_desc);
        single_step.dependOn(&run_bench.step);
        bench_step.dependOn(&run_bench.step);
        if (std.mem.eql(u8, bench.name, "webapi"))
            single_step.dependOn(ctx.webapi_contract_step);
    }
}

fn addSandboxBench(b: *std.Build, ctx: *const context_mod.Context) void {
    const module = b.createModule(.{
        .root_source_file = b.path("runtime/bench/sandbox.zig"),
        .target = ctx.opts.target,
        .optimize = ctx.opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    module.addImport("collo_bench_build_options", benchOptionsModule(b, ctx, ctx.opts.optimize));
    ctx.jsc_set.importInto(module, &.{
        .host,          .zygote,        .os,                .cgroup,         .server_main,
        .server_config, .server_routes, .server_supervisor, .egress_gateway,
    });
    const object = b.addObject(.{ .name = "sandbox-bench", .root_module = module });
    ctx.check_step.dependOn(&object.step);
    shims.configureBindingsTestObject(object, ctx.libc_file);
    shims.configureBoringSslShim(b, object, ctx.toolchain, ctx.opts.sanitizer);
    shims.configureHpackShim(b, object, ctx.patched_ls_hpack);
    object.root_module.addCSourceFiles(.{
        .files = &.{"runtime/bench/sandbox/client.cc"},
        .flags = toolchain_mod.cxxFlagsWithTarget(b, ctx.toolchain, &.{
            "-std=c++20",                    "-fno-exceptions",           "-fno-rtti",
            "-DLSHPACK_DEC_HTTP1X_OUTPUT=0", "-DLSHPACK_DEC_CALC_HASH=0",
        }, ctx.opts.sanitizer),
    });
    const linked = link_mod.addJscLink(b, ctx.link_ctx, .{
        .name = "sandbox-bench",
        .object = object,
        .bridge = ctx.bridge,
        .sanitizer = ctx.opts.sanitizer,
    });
    const install = b.addInstallBinFile(linked.executable, "sandbox-bench");
    const install_step = b.step(
        "install-microbench",
        "Install production-network sandbox microbench and cgroup tooling without running it",
    );
    install_step.dependOn(&install.step);
    install_step.dependOn(b.getInstallStep());
    inline for (.{
        .{ "bench-cold-start", "cold", "Measure local HTTP send through fresh sandbox handler entry" },
        .{ "bench-memory", "memory", "Measure cgroup marginal cost and per-process shared/private memory" },
    }) |entry| {
        const run = link_mod.runLinkedExecutable(b, linked, ctx.opts.sanitizer, &.{entry[1]});
        run.setEnvironmentVariable("COLLO_BENCH_WSL_CONFIG", b.getInstallPath(.bin, "wsl-config"));
        run.setEnvironmentVariable("COLLO_BENCH_CACHE_ROOT", b.pathFromRoot(".zig-cache"));
        run.step.dependOn(install_step);
        b.step(entry[0], entry[2]).dependOn(&run.step);
    }
}

/// A bench root that ships as an executable compiles and links in one step, so
/// `check` cannot reuse that artifact — it gets an object over a second module
/// on the same root instead. The object carries only the Zig graph: the C
/// shims and BoringSSL archives the executable links resolve symbols, never
/// types, and leaving them out is what keeps the gate down to a compile.
fn addCheckObject(
    b: *std.Build,
    ctx: *const context_mod.Context,
    name: []const u8,
    module: *std.Build.Module,
) void {
    const object = b.addObject(.{
        .name = b.fmt("{s}-check", .{name}),
        .root_module = module,
    });
    ctx.check_step.dependOn(&object.step);
}

fn compressionBenchModule(
    b: *std.Build,
    ctx: *const context_mod.Context,
    bench_options_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("runtime/bench/compression_codecs.zig"),
        .target = ctx.opts.target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = false,
    });
    module.addImport("collo_bench_build_options", bench_options_module);
    addJsWorkloadImports(b, module);
    return module;
}

fn egressBenchModule(
    b: *std.Build,
    ctx: *const context_mod.Context,
    bench: EgressBench,
    stub_release: *const modules_mod.ModuleSet,
    bench_options_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(bench.file),
        .target = ctx.opts.target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = true,
    });
    module.addImport("collo_bench_build_options", bench_options_module);
    module.addImport(modules_mod.importName(bench.import), stub_release.get(bench.import));
    if (bench.import_bindings)
        module.addImport("collo_bindings", stub_release.get(.bindings));
    if (bench.tls_test_shim)
        module.addImport("collo_test_tls_shim", shims.tlsTestShimModule(b, ctx.opts.target, .ReleaseFast));
    return module;
}

const EgressBench = struct {
    file: []const u8,
    name: []const u8,
    step_name: []const u8,
    step_desc: []const u8,
    import: modules_mod.ModuleId,
    import_bindings: bool = false,
    tls_test_shim: bool = false,
    install: bool = false,
};

const egress_benches = [_]EgressBench{
    .{
        .file = "runtime/bench/egress_tls.zig",
        .name = "egress_tls",
        .step_name = "bench-egress-tls",
        .step_desc = "Benchmark the BIO/io_uring HTTP/2 TLS egress data path",
        .import = .egress_pool,
        .tls_test_shim = true,
    },
    .{
        .file = "runtime/bench/egress_h2_engine.zig",
        .name = "egress_h2_engine",
        .step_name = "bench-egress-h2-engine",
        .step_desc = "Measure egress engine HTTP/2 owner-thread throughput across engines/connectors/origins/streams",
        .import = .egress_client,
        .import_bindings = true,
        .tls_test_shim = true,
        .install = true,
    },
    .{
        .file = "runtime/bench/egress_http1.zig",
        .name = "egress_http1",
        .step_name = "bench-egress-http1",
        .step_desc = "Compare HTTP/1 close, keep-alive, and streaming decompression egress",
        .import = .egress_client,
        .import_bindings = true,
    },
};

fn addEgressBenches(b: *std.Build, ctx: *const context_mod.Context, bench_step: *std.Build.Step) void {
    // JSC-free data-plane benches: always ReleaseFast, stub bindings.
    const stub_release = modules_mod.buildModuleGraph(b, .{
        .target = ctx.opts.target,
        .optimize = .ReleaseFast,
        .bindings = .h2_stub,
        .toolchain = ctx.toolchain,
        .zstd_link = ctx.zstd_link,
    });
    const bench_options_module = benchOptionsModule(b, ctx, .ReleaseFast);

    addCheckObject(
        b,
        ctx,
        "compression_codecs",
        compressionBenchModule(b, ctx, bench_options_module),
    );
    const compression_exe = b.addExecutable(.{
        .name = "compression_codecs",
        .root_module = compressionBenchModule(b, ctx, bench_options_module),
    });
    const compression_run = b.addRunArtifact(compression_exe);
    compression_run.setCwd(b.path("."));
    const compression_step = b.step(
        "bench-compression-codecs",
        "Compare identity, zstd, and Brotli on route sources, configuration JSON and random bytes",
    );
    compression_step.dependOn(&compression_run.step);
    bench_step.dependOn(&compression_run.step);

    for (egress_benches) |bench| {
        addCheckObject(
            b,
            ctx,
            bench.name,
            egressBenchModule(b, ctx, bench, &stub_release, bench_options_module),
        );
        const bench_exe = b.addExecutable(.{
            .name = bench.name,
            .root_module = egressBenchModule(b, ctx, bench, &stub_release, bench_options_module),
        });
        shims.configureBoringSslShim(b, bench_exe, ctx.toolchain, .{});
        if (bench.tls_test_shim)
            shims.configureBoringSslTestShim(b, bench_exe, ctx.toolchain, .{});
        shims.configureHpackShim(b, bench_exe, ctx.patched_ls_hpack);
        shims.linkBoringSslArchives(b, bench_exe, ctx.opts.boringssl_build_dir);

        const single_step = b.step(bench.step_name, bench.step_desc);
        if (bench.install)
            single_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
        const run = b.addRunArtifact(bench_exe);
        single_step.dependOn(&run.step);
        bench_step.dependOn(&run.step);
    }
}
