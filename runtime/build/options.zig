//! Single place where every -D flag is declared, defaulted and cross-validated.
//! All options are declared unconditionally so any flag is legal with any step.
const std = @import("std");
const builtin = @import("builtin");
const shims = @import("shims.zig");
const zstd = @import("zstd.zig");
const buildtool = @import("buildtool.zig");

/// The engine's CMake configuration, independent of the Zig optimize mode: the
/// dev loop links a Debug or ReleaseSafe runtime against the Release engine,
/// and the Debug engine exists for sanitized bindings smokes.
pub const JscProfile = enum { release, debug };

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    webapi_compat: bool,
    sanitizer: shims.BindingsSanitizer,
    jsc_profile: JscProfile,
    /// True admits the engine already in runtime/deps/jsc-build by its provenance and
    /// fails instead of building when it is stale.
    jsc_prebuilt: bool,
    jsc_build_dir: []const u8,
    webkit_source_dir: []const u8,
    boringssl_build_dir: []const u8,
    /// `-Dboringssl-build-dir` exactly as given. Null means no override, and
    /// every consumer then derives the directory from ITS OWN target — the dev
    /// graph from the host target, each release step from the architecture it
    /// builds for. A single resolved string cannot serve both.
    boringssl_build_dir_override: ?[]const u8,
    /// Flag-level choice; build.zig collapses `auto` via `zstd.resolveChoice`
    /// once the toolchain is discovered. A consumer that builds its own
    /// toolchain — the release steps do — must resolve against that one, never
    /// against this raw value.
    zstd_link: zstd.LinkChoice,
    // Toolchain knobs are pinned constants with env escape hatches; they are
    // deliberately not part of the -D surface.
    cxx_stdlib_version: []const u8,
    cxx_sysroot: []const u8,
    native_cxx_linker: []const u8,
    compiler_rt_builtins: ?[]const u8,
    /// Release-step -mcpu (COLLO_RELEASE_MCPU); null builds generic baseline.
    release_mcpu: ?[]const u8,
};

pub fn parse(b: *std.Build) Options {
    const webapi_compat = b.option(
        bool,
        "webapi-compat",
        "Include JS WebAPI compatibility tests in zig build test",
    ) orelse false;

    const sanitize = b.option(
        enum { none, address },
        "sanitize",
        "Sanitizer for the JSC bindings test steps: none or address (ASan+LSan)",
    );
    const sanitizer: shims.BindingsSanitizer = if (sanitize) |mode| switch (mode) {
        .none => .{ .mode = .none },
        .address => .{ .mode = .address_leak },
    } else shims.parseBindingsSanitizer(b.graph.env_map.get("COLLO_SANITIZE") orelse "none");

    const target = b.standardTargetOptions(.{ .default_target = defaultTargetQuery() });
    const optimize = b.standardOptimizeOption(.{});

    const jsc_profile = b.option(
        JscProfile,
        "jsc-profile",
        "Engine build: release (default) or debug (engine asserts, for sanitized bindings smokes)",
    ) orelse .release;
    const jsc_prebuilt = b.option(
        bool,
        "jsc-prebuilt",
        "Admit the engine in runtime/deps/jsc-build by provenance; fail instead of building when stale",
    ) orelse false;

    const triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
    const engine = engineDirs(b, triple, jscProfileName(b, jsc_profile, null));

    const boringssl_build_dir_override = b.option(
        []const u8,
        "boringssl-build-dir",
        "Directory containing BoringSSL libssl.a and libcrypto.a",
    );
    const zstd_link_raw = b.option(
        []const u8,
        "zstd-link",
        "zstd link mode: auto (default: static when libzstd.a exists, else system-dynamic), static, or system-dynamic",
    ) orelse "auto";
    const zstd_link = zstd.parseLinkChoice(zstd_link_raw) orelse std.process.fatal(
        "invalid -Dzstd-link={s}; expected auto, static or system-dynamic",
        .{zstd_link_raw},
    );

    return .{
        .target = target,
        .optimize = optimize,
        .webapi_compat = webapi_compat,
        .sanitizer = sanitizer,
        .jsc_profile = jsc_profile,
        .jsc_prebuilt = jsc_prebuilt,
        .jsc_build_dir = engine.jsc,
        .webkit_source_dir = engine.webkit_src,
        .boringssl_build_dir_override = boringssl_build_dir_override,
        .boringssl_build_dir = boringssl_build_dir_override orelse
            defaultBoringSslBuildDir(target.result.cpu.arch),
        .zstd_link = zstd_link,
        .cxx_stdlib_version = b.graph.env_map.get("COLLO_CXX_STDLIB_VERSION") orelse "13",
        .cxx_sysroot = b.graph.env_map.get("COLLO_CXX_SYSROOT") orelse "",
        .native_cxx_linker = b.graph.env_map.get("CXX") orelse "c++",
        .compiler_rt_builtins = if (b.graph.env_map.get("COLLO_COMPILER_RT_BUILTINS")) |path|
            path
        else
            discoverCompilerRtBuiltins(b, target.result.cpu.arch),
        .release_mcpu = b.graph.env_map.get("COLLO_RELEASE_MCPU"),
    };
}

/// BoringSSL archives are per-architecture and the tree carries one directory
/// per arch it links. Deriving the directory from the target is what keeps a
/// cross build from linking the host's archives: the mismatch is invisible
/// until the final link, where it surfaces as undefined symbols rather than as
/// "you picked the wrong directory".
pub fn defaultBoringSslBuildDir(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "runtime/deps/boringssl/build-aarch64",
        else => "runtime/deps/boringssl/build",
    };
}

pub const EngineDirs = struct {
    jsc: []const u8,
    webkit_src: []const u8,
};

/// `runtime/deps/jsc-build/<triple>/<profile>/{src,build}`, absolute. The buildtool derives
/// the same layout and refuses anything else, so a drift between the two derivations fails
/// loudly instead of building into the wrong place.
pub fn engineDirs(b: *std.Build, triple: []const u8, profile: []const u8) EngineDirs {
    const base = b.pathFromRoot(b.fmt("{s}/{s}/{s}", .{ buildtool.engine_generated_relative, triple, profile }));
    return .{
        .jsc = b.pathJoin(&.{ base, "build" }),
        .webkit_src = b.pathJoin(&.{ base, "src" }),
    };
}

/// Dev default: native on linux-gnu hosts of any arch; elsewhere fall back to
/// x86_64-linux-gnu (configure stays alive; steps that need the toolchain fail
/// with a clear message at build time).
fn defaultTargetQuery() std.Target.Query {
    if (builtin.target.os.tag == .linux and builtin.target.abi == .gnu)
        return .{};
    return .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu };
}

pub fn jscCmakeBuildType(profile: JscProfile) []const u8 {
    return switch (profile) {
        .release => "Release",
        .debug => "Debug",
    };
}

/// Engine profile directory name: release|debug, plus -<mcpu> when the release
/// step pins a CPU model.
pub fn jscProfileName(b: *std.Build, profile: JscProfile, mcpu: ?[]const u8) []const u8 {
    if (mcpu) |cpu|
        return b.fmt("{s}-{s}", .{ @tagName(profile), cpu });
    return @tagName(profile);
}

pub fn discoverCompilerRtBuiltins(b: *std.Build, arch: std.Target.Cpu.Arch) ?[]const u8 {
    const arch_name = switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };
    for ([_][]const u8{ "19", "18" }) |llvm_version| {
        const candidate = b.fmt(
            "/usr/lib/llvm-{s}/lib/clang/{s}/lib/linux/libclang_rt.builtins-{s}.a",
            .{ llvm_version, llvm_version, arch_name },
        );
        std.fs.accessAbsolute(candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}
