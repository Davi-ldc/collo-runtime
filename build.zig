//! Root build: parse options, assemble the toolchain, the pinned native
//! dependencies, the engine and the bridge once, build the two module graphs,
//! then hand step wiring to build/{tests,smoke,bench}.zig. Production
//! artifacts live behind the `release`/`release-x86` steps.
const std = @import("std");
const options_mod = @import("runtime/build/options.zig");
const toolchain_mod = @import("runtime/build/toolchain.zig");
const shims = @import("runtime/build/shims.zig");
const jsc_mod = @import("runtime/build/jsc.zig");
const modules_mod = @import("runtime/build/modules.zig");
const link_mod = @import("runtime/build/link.zig");
const context_mod = @import("runtime/build/context.zig");
const tests_mod = @import("runtime/build/tests.zig");
const smoke_mod = @import("runtime/build/smoke.zig");
const bench_mod = @import("runtime/build/bench.zig");
const release_mod = @import("runtime/build/release.zig");
const codecs_mod = @import("runtime/build/codecs.zig");
const deps_mod = @import("runtime/build/deps.zig");
const pins = @import("runtime/build/pins.zig");
const tool_mod = @import("runtime/build/tool.zig");
const cachefs = @import("runtime/build/cachefs.zig");

pub fn build(b: *std.Build) void {
    cachefs.assertCacheNotOnDrvfs(b);
    const opts = options_mod.parse(b);
    const cxx_sysroot = options_mod.cxxSysrootFor(b, &opts, opts.target);

    const toolchain = b.allocator.create(toolchain_mod.ToolchainPaths) catch @panic("OOM");
    toolchain.* = toolchain_mod.discover(
        b,
        opts.target,
        opts.cxx_stdlib_version,
        cxx_sysroot,
        opts.native_cxx_linker,
        opts.compiler_rt_builtins,
    ) orelse std.process.fatal(
        "cross-compiling the dev graph requires COLLO_CXX_SYSROOT=<target sysroot>; " ++
            "the release steps carry their own toolchain",
        .{},
    );
    const libc_file = toolchain_mod.createLibcConfig(b, toolchain);

    const tool = b.allocator.create(tool_mod.Tool) catch @panic("OOM");
    tool.* = tool_mod.create(b);
    // ICU is an input of the engine, so -Djsc-prebuilt admits every ICU
    // build with the engine instead of building it.
    const native = deps_mod.Native.create(b, tool, if (opts.jsc_prebuilt) .admit else .build);
    addDependencySteps(b, tool);

    // ICU and BoringSSL for this target, built or admitted by their stamps.
    const native_target: deps_mod.Target = .{
        .target = opts.target,
        .cxx_sysroot = cxx_sysroot,
        .mcpu = toolchain.target_mcpu,
    };
    const icu = native.icu(native_target);
    const boringssl = native.boringssl(native_target);
    b.step("icu", "Build (or admit, with -Djsc-prebuilt) the pinned ICU and its data for this target")
        .dependOn(&icu.step.step);
    b.step("boringssl", "Build the pinned BoringSSL with runtime/patches/boringssl for this target")
        .dependOn(&boringssl.step.step);
    const verify_trees = &native.verifyCompiledTrees().step;
    const codecs = b.allocator.create(codecs_mod.Codecs) catch @panic("OOM");
    codecs.* = codecs_mod.build(b, opts.target, verify_trees);
    codecs_mod.addCheckTo(b.step("codecs", "Compile the pinned zlib, brotli and zstd and translate their headers for this target"), codecs);

    const jsc_cmake_build_type = options_mod.jscCmakeBuildType(opts.jsc_profile);
    const engine_inputs: jsc_mod.EngineInputs = .{
        .target = opts.target,
        .cmake_build_type = jsc_cmake_build_type,
        .jsc_build_dir = opts.jsc_build_dir,
        .webkit_source_dir = opts.webkit_source_dir,
        .cxx_sysroot = cxx_sysroot,
        .mcpu = toolchain.target_mcpu,
        .icu = icu,
    };
    const jsc = jsc_mod.JscBuild{
        .cmake_build_type = jsc_cmake_build_type,
        .build_dir = opts.jsc_build_dir,
        .webkit_source_dir = opts.webkit_source_dir,
        .step = if (opts.jsc_prebuilt)
            jsc_mod.addPrebuiltValidationStep(b, tool, engine_inputs)
        else
            jsc_mod.addBuildStep(b, tool, engine_inputs),
    };
    if (jsc.step) |step|
        b.step("jsc", "Build (or admit, with -Djsc-prebuilt) the pinned, patched engine for this target and -Djsc-profile").dependOn(&step.step);
    b.step("webkit-authoring", "Create runtime/deps/webkit-authoring on branch collo-patches with the series applied")
        .dependOn(&jsc_mod.addWebkitStep(b, tool, "webkit-authoring").step);
    b.step("webkit-export", "Regenerate runtime/patches/webkit from the collo-patches branch")
        .dependOn(&jsc_mod.addWebkitStep(b, tool, "webkit-export").step);

    const patched_ls_hpack = shims.addPatchedLsHpackSourceStep(b, tool, verify_trees);

    const jsc_set = modules_mod.buildModuleGraph(b, .{
        .target = opts.target,
        .optimize = opts.optimize,
        .bindings = .jsc,
        .codecs = codecs,
    });
    const stub_set = modules_mod.buildModuleGraph(b, .{
        .target = opts.target,
        .optimize = opts.optimize,
        .bindings = .h2_stub,
        .codecs = codecs,
    });

    const bridge_module = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libcpp = false,
        .sanitize_c = .off,
    });
    const bridge = b.addLibrary(.{
        .name = "collo_jsc_bindings",
        .root_module = bridge_module,
        .use_lld = false,
    });
    if (jsc.step) |step|
        bridge.step.dependOn(&step.step);
    shims.configureBridgeLibrary(
        b,
        bridge,
        libc_file,
        toolchain,
        jsc.cmake_build_type,
        jsc.build_dir,
        jsc.webkit_source_dir,
        .{ .icu = icu.headers(b), .boringssl = boringssl.headers(), .codecs = codecs },
        opts.sanitizer,
    );

    const link_ctx = link_mod.LinkContext{
        .toolchain = toolchain,
        .jsc_build_dir = jsc.build_dir,
        .jsc_step = jsc.step,
        .icu = icu,
        .boringssl = boringssl,
        .codecs = codecs,
        .link_quadmath = opts.target.result.cpu.arch == .x86_64,
        .compiler_rt_carrier = link_mod.addCompilerRtCarrier(b, opts.target, opts.optimize),
    };

    const collo_object = b.addObject(.{
        .name = "collo",
        .root_module = jsc_set.get(.main),
    });
    shims.configureBindingsTestObject(collo_object, libc_file);
    shims.configureBoringSslShim(b, collo_object, toolchain, boringssl.headers(), opts.sanitizer);
    shims.configureHpackShim(b, collo_object, patched_ls_hpack);
    const linked_collo = link_mod.addJscLink(b, link_ctx, .{
        .name = "collo",
        .object = collo_object,
        .bridge = bridge,
        .sanitizer = opts.sanitizer,
    });
    const install_collo = b.addInstallBinFile(linked_collo.executable, "collo");
    b.getInstallStep().dependOn(&install_collo.step);
    const run_collo = link_mod.runLinkedWithVerbatimArgs(b, linked_collo, opts.sanitizer);
    b.step("run-collo", "Run the collo binary (`-- serve <collo.json | entry.js> [--listen <host:port>]`)").dependOn(&run_collo.step);

    // A STRING, never addOptionPath. A generated LazyPath makes the options
    // module carry a step dependency, and the build runner propagates that to
    // every Compile whose module graph reaches it — so each domain test object
    // would wait on the full production link before it could be type-checked.
    // The path is only ever read at RUN time (spawnZygote), so the install
    // location is enough here and the Run steps carry the artifact dependency.
    const process_options = b.addOptions();
    process_options.addOption([]const u8, "collo_executable_path", b.getInstallPath(.bin, "collo"));
    const process_options_module = process_options.createModule();

    const bindings_support_module = b.createModule(.{
        .root_source_file = b.path("runtime/tests/support/bindings/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    jsc_set.importInto(bindings_support_module, &.{ .bindings, .ipc, .worker });

    const zygote_support_module = b.createModule(.{
        .root_source_file = b.path("runtime/tests/support/zygote/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .link_libcpp = false,
    });
    jsc_set.importInto(zygote_support_module, &.{ .bindings, .zygote, .os, .worker, .host, .ipc });
    zygote_support_module.addImport("collo_process_options", process_options_module);

    const validate_tool = b.addExecutable(.{
        .name = "validate-webapi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/build/validate_webapi_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const validate_run = b.addRunArtifact(validate_tool);
    validate_run.addDirectoryArg(b.path("runtime/tests/webapi"));
    _ = validate_run.addOutputFileArg("webapi-contracts.ok");
    validate_run.addPrefixedFileArg("--bench=", b.path("runtime/bench/webapi.zig"));
    validate_run.addPrefixedFileArg("--bench=", b.path("runtime/build/bench.zig"));
    validate_run.addPrefixedFileArg("--suite=", b.path("runtime/tests/webapi/suites.zig"));
    validate_run.addPrefixedFileArg("--suite=", b.path("runtime/tests/webapi/forked.zig"));
    // The cache knows a directory argument by its path alone, so a cached
    // verdict would miss a fixture added to or edited in the tree. The check
    // reads a few hundred kilobytes, so it runs every time.
    validate_run.has_side_effects = true;

    const check_step = b.step("check", "Type-check every test and bench root (no link, no run)");
    const ctx = context_mod.Context{
        .opts = &opts,
        .toolchain = toolchain,
        .libc_file = libc_file,
        .codecs = codecs,
        .boringssl = boringssl,
        .jsc = jsc,
        .link_ctx = link_ctx,
        .bridge = bridge,
        .patched_ls_hpack = patched_ls_hpack,
        .jsc_set = jsc_set,
        .stub_set = stub_set,
        .bindings_support_module = bindings_support_module,
        .zygote_support_module = zygote_support_module,
        .process_options_module = process_options_module,
        .collo_bin = linked_collo.executable,
        .install_collo_step = &install_collo.step,
        .check_step = check_step,
        .webapi_contract_step = &validate_run.step,
        .git_or_deploy_hash = discoverGitOrDeployHash(b),
    };
    const smoke_preflight = smoke_mod.addPreflight(b);
    const test_lanes = tests_mod.addAll(b, &ctx, smoke_preflight);
    bench_mod.addAll(b, &ctx);
    release_mod.addReleaseSteps(b, &opts, .{
        .tool = tool,
        .native = native,
        .patched_ls_hpack = patched_ls_hpack,
    });
    addCommentTools(b, &ctx, test_lanes.aggregate, check_step);

    const cgroup_env_exe = b.addExecutable(.{
        .name = "wsl-config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dev/wsl/cgroup_env.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .link_libc = true,
            .link_libcpp = false,
        }),
    });
    b.installArtifact(cgroup_env_exe);
    const run_cgroup_env = b.addRunArtifact(cgroup_env_exe);
    if (b.args) |args|
        run_cgroup_env.addArgs(args);
    const wsl_config_step = b.step(
        "wsl-config",
        "Check or enter the WSL cgroup environment for kernel tests",
    );
    wsl_config_step.dependOn(&run_cgroup_env.step);
    // Keep zig-out/bin/wsl-config fresh: the documented root flows
    // (`sudo ./zig-out/bin/wsl-config prepare|run`) go through the installed
    // binary, never `sudo zig build` (root-owned cache).
    const install_wsl_config = b.addInstallArtifact(cgroup_env_exe, .{});
    wsl_config_step.dependOn(&install_wsl_config.step);

    smoke_mod.addStep(b, &ctx, .{
        .preflight = smoke_preflight,
        .lanes = test_lanes,
        .install_wsl_config = &install_wsl_config.step,
    });
}

/// `deps-provision` fetches every pinned tree (runtime/build/pins.zig) at its
/// pin into runtime/deps, and `webkit-provision` only the engine's, through
/// the same run, so asking for both never fetches one tree twice at once.
/// Neither replaces a tree that exists, so both are safe to run again.
fn addDependencySteps(b: *std.Build, tool: *const tool_mod.Tool) void {
    const all = comptime std.enums.values(pins.Dependency);
    const besides_webkit = comptime blk: {
        var list: [all.len - 1]pins.Dependency = undefined;
        var count: usize = 0;
        for (all) |dependency| {
            if (dependency == .webkit) continue;
            list[count] = dependency;
            count += 1;
        }
        break :blk list;
    };
    const webkit = deps_mod.addProvisionStep(b, tool, "provision webkit", &.{.webkit});
    const others = deps_mod.addProvisionStep(b, tool, "provision pinned trees", &besides_webkit);
    b.step("webkit-provision", "Fetch oven-sh/WebKit at the pin into runtime/deps/WebKit")
        .dependOn(&webkit.step);
    const provision = b.step("deps-provision", "Fetch every pinned dependency tree at its pin into runtime/deps");
    provision.dependOn(&webkit.step);
    provision.dependOn(&others.step);
}

/// The comment tools in dev/comments run on the build host for any target.
/// `comment-guard` proves an edit changed only comments and whitespace;
/// `provenance-baseline` lowers the baseline of the comment provenance gate in
/// runtime/tests/conventions.zig, from the repository root, and never raises it.
fn addCommentTools(
    b: *std.Build,
    ctx: *const context_mod.Context,
    test_aggregate: tests_mod.Aggregate,
    check_step: *std.Build.Step,
) void {
    const guard_exe = b.addExecutable(.{
        .name = "comment-guard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dev/comments/comment_guard.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(guard_exe);
    const run_guard = b.addRunArtifact(guard_exe);
    if (b.args) |args|
        run_guard.addArgs(args);
    b.step("comment-guard", "Prove two files or trees differ only in comments (`-- <before> <after>`)")
        .dependOn(&run_guard.step);

    const baseline_exe = b.addExecutable(.{
        .name = "provenance-baseline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dev/comments/provenance_baseline.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_baseline = b.addRunArtifact(baseline_exe);
    run_baseline.setCwd(b.path("."));
    run_baseline.has_side_effects = true;
    if (b.args) |args|
        run_baseline.addArgs(args);
    b.step("provenance-baseline", "Lower the comment provenance baseline to the current counts (`-- --list` prints every marker)")
        .dependOn(&run_baseline.step);

    const comment_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("dev/comments/tests/all.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    tests_mod.useCustomRunner(b, comment_tests);
    comment_tests.root_module.addImport("collo_comments", b.createModule(.{
        .root_source_file = b.path("dev/comments/root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    check_step.dependOn(&comment_tests.step);
    const run_comment_tests = test_aggregate.addRun(b, ctx, .{ .compile = comment_tests });
    b.step("comment-guard-test", "Test the comment lexers and comment-guard (JSC-free)")
        .dependOn(&run_comment_tests.step);
}

fn discoverGitOrDeployHash(b: *std.Build) []const u8 {
    if (b.graph.env_map.get("COLLO_DEPLOY_HASH")) |hash|
        return hash;
    std.fs.cwd().access(".git", .{}) catch return "unknown";
    var code: u8 = 0;
    const stdout = b.runAllowFail(&.{ "git", "rev-parse", "--short=12", "HEAD" }, &code, .Ignore) catch
        return "unknown";
    if (code != 0)
        return "unknown";
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0)
        return "unknown";
    return trimmed;
}
