//! Production artifact steps. `zig build release` is the product build:
//! aarch64-linux-gnu + ReleaseFast, with the CPU model
//! pinned via COLLO_RELEASE_MCPU (pending the lscpu reading from the Ampere A4
//! VM; null builds generic baseline). `release-x86` is the x86_64 variant.
const std = @import("std");
const options_mod = @import("options.zig");
const toolchain_mod = @import("toolchain.zig");
const shims = @import("shims.zig");
const jsc_mod = @import("jsc.zig");
const modules_mod = @import("modules.zig");
const link_mod = @import("link.zig");
const zstd_mod = @import("zstd.zig");

pub fn addReleaseSteps(
    b: *std.Build,
    opts: *const options_mod.Options,
    patched_ls_hpack: std.Build.LazyPath,
) void {
    addReleaseStep(b, opts, patched_ls_hpack, .{
        .step_name = "release",
        .description = "Build the production collo binary (aarch64 + ReleaseFast)",
        .arch_os_abi = "aarch64-linux-gnu",
        .arch = .aarch64,
        .mcpu = opts.release_mcpu,
        .artifact_name = "collo-aarch64",
    });
    addReleaseStep(b, opts, patched_ls_hpack, .{
        .step_name = "release-x86",
        .description = "Build the production collo binary for x86_64 (ReleaseFast)",
        .arch_os_abi = "x86_64-linux-gnu",
        .arch = .x86_64,
        .mcpu = null,
        .artifact_name = "collo-x86_64",
    });
}

const ReleaseSpec = struct {
    step_name: []const u8,
    description: []const u8,
    arch_os_abi: []const u8,
    arch: std.Target.Cpu.Arch,
    mcpu: ?[]const u8,
    artifact_name: []const u8,
};

fn addReleaseStep(
    b: *std.Build,
    opts: *const options_mod.Options,
    patched_ls_hpack: std.Build.LazyPath,
    spec: ReleaseSpec,
) void {
    const step = b.step(spec.step_name, spec.description);
    const query = std.Target.Query.parse(.{
        .arch_os_abi = spec.arch_os_abi,
        .cpu_features = spec.mcpu,
    }) catch |err| {
        step.dependOn(&b.addFail(b.fmt(
            "invalid COLLO_RELEASE_MCPU '{s}': {s}",
            .{ spec.mcpu orelse "", @errorName(err) },
        )).step);
        return;
    };
    const target = b.resolveTargetQuery(query);

    const compiler_rt = b.graph.env_map.get("COLLO_COMPILER_RT_BUILTINS") orelse
        options_mod.discoverCompilerRtBuiltins(b, spec.arch) orelse {
        step.dependOn(&b.addFail(b.fmt(
            "{s}: missing libclang_rt.builtins-{s}.a; install llvm-19 or set COLLO_COMPILER_RT_BUILTINS",
            .{ spec.step_name, @tagName(spec.arch) },
        )).step);
        return;
    };
    const toolchain = toolchain_mod.discover(
        b,
        target,
        opts.cxx_stdlib_version,
        opts.cxx_sysroot,
        opts.native_cxx_linker,
        compiler_rt,
    ) orelse {
        step.dependOn(&b.addFail(b.fmt(
            "{s}: cross-compiling requires COLLO_CXX_SYSROOT=<{s} sysroot>",
            .{ spec.step_name, spec.arch_os_abi },
        )).step);
        return;
    };
    const toolchain_ptr = b.allocator.create(toolchain_mod.ToolchainPaths) catch @panic("OOM");
    toolchain_ptr.* = toolchain;

    // Resolved against THIS step's toolchain, not the dev one. `-Dzstd-link`
    // defaults to `auto`, and `auto` is a question about a specific target's
    // sysroot — asking it of the host answers for the wrong machine, and
    // reading the raw choice answers "not static" for every default build.
    if (zstd_mod.resolveChoice(b, toolchain_ptr, opts.zstd_link) != .static) {
        step.dependOn(&b.addFail(b.fmt(
            "{s}: production release requires a static zstd for {s}; none found and -Dzstd-link did not force one",
            .{ spec.step_name, spec.arch_os_abi },
        )).step);
        return;
    }

    const libc_file = toolchain_mod.createLibcConfig(b, toolchain_ptr);

    const triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
    // One derivation, shared with options.zig. A second copy here is how a tree ends up with dev builds
    // and release builds disagreeing about where the engine lives.
    const engine = options_mod.engineDirs(b, triple, options_mod.jscProfileName(b, .release, toolchain_ptr.target_mcpu));
    const jsc_cmake_build_type = options_mod.jscCmakeBuildType(.release);
    const jsc = jsc_mod.JscBuild{
        .cmake_build_type = jsc_cmake_build_type,
        .build_dir = engine.jsc,
        .webkit_source_dir = engine.webkit_src,
        .step = jsc_mod.addBuildStep(
            b,
            target,
            jsc_cmake_build_type,
            engine.jsc,
            engine.webkit_src,
            opts.cxx_sysroot,
            toolchain_ptr.target_mcpu,
        ),
    };

    const set = modules_mod.buildModuleGraph(b, .{
        .target = target,
        .optimize = .ReleaseFast,
        .bindings = .jsc,
        .toolchain = toolchain_ptr,
        .zstd_link = .static, // guarded above: release refuses any other choice
    });
    const bridge_module = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libcpp = false,
        .sanitize_c = .off,
    });
    const bridge = b.addLibrary(.{
        .name = b.fmt("collo_jsc_bindings_{s}", .{spec.step_name}),
        .root_module = bridge_module,
        .use_lld = false,
    });
    if (jsc.step) |jsc_step|
        bridge.step.dependOn(&jsc_step.step);
    shims.configureBridgeLibrary(
        b,
        bridge,
        libc_file,
        toolchain_ptr,
        jsc.cmake_build_type,
        jsc.build_dir,
        jsc.webkit_source_dir,
        .{},
    );

    const collo_object = b.addObject(.{
        .name = spec.artifact_name,
        .root_module = set.get(.main),
    });
    shims.configureBindingsTestObject(collo_object, libc_file);
    shims.configureBoringSslShim(b, collo_object, toolchain_ptr, .{});
    shims.configureHpackShim(b, collo_object, patched_ls_hpack);

    const linked = link_mod.addJscLink(b, .{
        .toolchain = toolchain_ptr,
        .jsc_build_dir = jsc.build_dir,
        .jsc_step = jsc.step,
        // Per target, not per host: an explicit -Dboringssl-build-dir wins,
        // otherwise each release step takes the archives built for the
        // architecture it is producing.
        .boringssl_build_dir = opts.boringssl_build_dir_override orelse
            options_mod.defaultBoringSslBuildDir(spec.arch),
        .zstd_link = .static, // guarded above: release refuses any other choice
        .link_quadmath = spec.arch == .x86_64,
        .compiler_rt_carrier = link_mod.addCompilerRtCarrier(b, target, .ReleaseFast),
    }, .{
        .name = spec.artifact_name,
        .object = collo_object,
        .bridge = bridge,
    });
    const install = b.addInstallBinFile(linked.executable, spec.artifact_name);
    step.dependOn(&install.step);
}
