//! The one place that knows how to link a Zig object against the JSC bridge,
//! the JSC static archives, BoringSSL, ICU and compiler-rt.
const std = @import("std");
const toolchain_mod = @import("toolchain.zig");
const shims = @import("shims.zig");
const zstd_mod = @import("zstd.zig");

pub const LinkContext = struct {
    toolchain: *const toolchain_mod.ToolchainPaths,
    jsc_build_dir: []const u8,
    jsc_step: ?*std.Build.Step.Run,
    boringssl_build_dir: []const u8,
    zstd_link: zstd_mod.LinkMode,
    link_quadmath: bool,
    /// Zig compiler-rt for the external link, from `addCompilerRtCarrier`.
    /// Built per (target, optimize) like every other object in the link.
    compiler_rt_carrier: *std.Build.Step.Compile,
};

/// The object that supplies Zig's compiler-rt to every executable this
/// module links. Objects in the link never bundle their own: a test
/// compilation exports bundled compiler-rt with internal linkage, so its
/// `__zig_probe_stack` references would stay unresolved (see
/// compiler_rt_carrier.zig).
pub fn addCompilerRtCarrier(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const carrier = b.addObject(.{
        .name = "compiler_rt_carrier",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/build/compiler_rt_carrier.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    carrier.bundle_compiler_rt = true;
    return carrier;
}

pub const LinkInputs = struct {
    name: []const u8,
    object: *std.Build.Step.Compile,
    bridge: *std.Build.Step.Compile,
    sanitizer: shims.BindingsSanitizer = .{},
};

pub const LinkedArtifact = struct {
    link: *std.Build.Step.Run,
    executable: std.Build.LazyPath,
};

pub fn addJscLink(b: *std.Build, ctx: LinkContext, in: LinkInputs) LinkedArtifact {
    const compiler_rt = ctx.toolchain.compiler_rt_builtins_path orelse std.process.fatal(
        "missing compiler-rt builtins archive for the C++ final link; install llvm-19 or set COLLO_COMPILER_RT_BUILTINS",
        .{},
    );
    const link = toolchain_mod.addCxxLinkCommand(b, ctx.toolchain);
    link.setName(b.fmt("link {s}", .{in.name}));
    if (ctx.jsc_step) |step|
        link.step.dependOn(&step.step);
    toolchain_mod.addCxxTargetArgs(link, ctx.toolchain);
    for (in.sanitizer.linkArgs()) |arg|
        link.addArg(arg);
    link.addArg("-no-pie");
    // lld emits no build-id note unless asked (native Ubuntu links get one
    // from distro specs); the release contract requires it — the JSC
    // bytecode cache version hashes it.
    link.addArg("-Wl,--build-id=sha1");
    link.addArg("-o");
    const executable = link.addOutputFileArg(in.name);
    link.addArg("-Wl,-z,noexecstack");

    link.addFileArg(in.object.getEmittedBin());
    // Zig-specific builtins come from the carrier, never from the external
    // driver's libclang_rt (linked below) and never bundled into `in.object`.
    link.addFileArg(ctx.compiler_rt_carrier.getEmittedBin());
    link.addArtifactArg(in.bridge);
    link.addArg("-Wl,--start-group");
    link.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ ctx.jsc_build_dir, "lib/libJavaScriptCore.a" }) });
    link.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ ctx.jsc_build_dir, "lib/libWTF.a" }) });
    link.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ ctx.jsc_build_dir, "lib/libbmalloc.a" }) });
    link.addArg("-Wl,--end-group");
    link.addFileArg(b.path(b.pathJoin(&.{ ctx.boringssl_build_dir, "libssl.a" })));
    link.addFileArg(b.path(b.pathJoin(&.{ ctx.boringssl_build_dir, "libcrypto.a" })));
    zstd_mod.addToCxxLink(b, link, ctx.toolchain, ctx.zstd_link);
    link.addArg("-ldl");
    link.addArg("-licuuc");
    link.addArg("-licui18n");
    link.addArg("-licudata");
    link.addArg("-latomic");
    link.addArg("-lm");
    if (ctx.link_quadmath)
        link.addArg("-lquadmath");
    link.addFileArg(.{ .cwd_relative = compiler_rt });
    if (ctx.toolchain.cxx_stdlib_static_archive) |archive|
        link.addFileArg(.{ .cwd_relative = archive })
    else
        link.addArg("-lstdc++");
    link.addArg("-lpthread");
    return .{
        .link = link,
        .executable = executable,
    };
}

/// The Run step every linked executable shares: it waits on the link, runs
/// the emitted binary with the step's configured args and carries the
/// sanitizer runtime env. The two public wrappers differ only in what they
/// do with `zig build <step> -- <args>`.
fn createRunStep(
    b: *std.Build,
    linked: LinkedArtifact,
    sanitizer: shims.BindingsSanitizer,
    configured_args: []const []const u8,
) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, "run linked executable");
    run.step.dependOn(&linked.link.step);
    run.addFileArg(linked.executable);
    for (configured_args) |arg|
        run.addArg(arg);
    if (sanitizer.runEnv()) |env|
        run.setEnvironmentVariable(env.key, env.value);
    return run;
}

/// Runs a linked test runner, with `zig build <step> -- <args>` placed
/// behind a literal `--forwarded` separator. For an executable with its own
/// command line use `runLinkedWithVerbatimArgs`.
pub fn runLinkedExecutable(
    b: *std.Build,
    linked: LinkedArtifact,
    sanitizer: shims.BindingsSanitizer,
    configured_args: []const []const u8,
) *std.Build.Step.Run {
    const run = createRunStep(b, linked, sanitizer, configured_args);
    // The custom runner keeps selectors BEFORE the separator as the step's
    // build-configured domain set and --filter selectors AFTER it as the
    // user set, selecting configured AND user — a forwarded filter narrows a
    // domain step, never widens it, and a forwarded --assert-partition is
    // rejected outright (a CLI arg must never widen a build-configured
    // partition contract). No CLI args → no separator → argv byte-identical
    // to the no-args build, so default-runner lanes (asan smoke, bench)
    // never see a stray argument.
    if (b.args) |args| {
        if (args.len != 0) {
            run.addArg("--forwarded");
            run.addArgs(args);
        }
    }
    return run;
}

/// Runs a linked program with `zig build <step> -- <args>` passed through
/// verbatim: for an executable with its own command line (`collo serve
/// <entry.js>`), which knows nothing of the `--forwarded` separator the
/// test runner behind `runLinkedExecutable` expects.
pub fn runLinkedWithVerbatimArgs(
    b: *std.Build,
    linked: LinkedArtifact,
    sanitizer: shims.BindingsSanitizer,
) *std.Build.Step.Run {
    const run = createRunStep(b, linked, sanitizer, &.{});
    if (b.args) |args|
        run.addArgs(args);
    return run;
}

pub fn addBindingsTestRunner(
    b: *std.Build,
    ctx: LinkContext,
    in: LinkInputs,
) *std.Build.Step.Run {
    return runLinkedExecutable(b, addJscLink(b, ctx, in), in.sanitizer, &.{});
}

pub fn addBindingsValgrindRunner(
    b: *std.Build,
    ctx: LinkContext,
    in: LinkInputs,
) *std.Build.Step.Run {
    const linked = addJscLink(b, ctx, in);
    const run = b.addSystemCommand(&.{
        "valgrind",
        "--leak-check=full",
        "--show-leak-kinds=definite,possible",
        "--errors-for-leak-kinds=definite,possible",
        "--track-origins=yes",
        "--error-exitcode=99",
    });
    run.step.dependOn(&linked.link.step);
    run.addFileArg(linked.executable);
    return run;
}
