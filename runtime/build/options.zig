//! Single place where every -D flag is declared, defaulted and cross-validated.
//! All options are declared unconditionally so any flag is legal with any step.
const std = @import("std");
const builtin = @import("builtin");
const shims = @import("shims.zig");
const buildtool = @import("buildtool.zig");

/// The engine's CMake configuration, independent of the Zig optimize mode: the
/// dev loop links a Debug or ReleaseSafe runtime against the Release engine,
/// and the Debug engine exists for sanitized bindings smokes.
pub const JscProfile = enum { release, debug };

/// The engine's page geometry on aarch64 Linux, whose kernels run with 4, 16 or 64 KiB pages.
/// JSC and libpas fix their block, page and granule sizes at compile time, each a multiple of the
/// kernel's page. `16k` applies the series addendum `arm64_pages16k_addendum`, which sizes them
/// for kernels with 4 or 16 KiB pages; `64k` builds the series alone, whose sizes also fit 64 KiB
/// pages and cost every process more memory on the other kernels. An x86_64 engine has one
/// geometry and ignores the option.
pub const Arm64Pages = enum { @"16k", @"64k" };

/// The directory under `runtime/patches/webkit/` that holds the 16 KiB geometry.
pub const arm64_pages16k_addendum = "arm64-pages16k";

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sanitizer: shims.BindingsSanitizer,
    jsc_profile: JscProfile,
    arm64_pages: Arm64Pages,
    /// The series addendum of the engine for `target` (`jscSeriesAddendum`).
    jsc_series_addendum: ?[]const u8,
    /// True admits the engine already in runtime/deps/jsc-build, and the ICU build it compiled
    /// against, by their provenance, and fails instead of building when either is stale.
    jsc_prebuilt: bool,
    jsc_build_dir: []const u8,
    webkit_source_dir: []const u8,
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
    const sanitize = b.option(
        enum { none, address, undefined },
        "sanitize",
        "Sanitizer for Collo's C++: none, address (ASan+LSan) or undefined (UBSan alignment and float-cast-overflow, aborting on a report)",
    );
    const sanitizer: shims.BindingsSanitizer = if (sanitize) |mode| switch (mode) {
        .none => .{ .mode = .none },
        .address => .{ .mode = .address_leak },
        .undefined => .{ .mode = .undefined_behavior },
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
        "Admit the engine and its ICU by provenance; fail instead of building when stale",
    ) orelse false;
    const arm64_pages = b.option(
        Arm64Pages,
        "arm64-pages",
        "Engine page geometry on aarch64: 16k (default; kernels with 4 or 16 KiB pages) or 64k (also 64 KiB-page kernels, at a memory cost per worker); x86_64 ignores it",
    ) orelse .@"16k";

    const triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
    const series_addendum = jscSeriesAddendum(target.result.cpu.arch, arm64_pages);
    const engine = engineDirs(b, triple, jscProfileName(b, jsc_profile, null, series_addendum));

    return .{
        .target = target,
        .optimize = optimize,
        .sanitizer = sanitizer,
        .jsc_profile = jsc_profile,
        .arm64_pages = arm64_pages,
        .jsc_series_addendum = series_addendum,
        .jsc_prebuilt = jsc_prebuilt,
        .jsc_build_dir = engine.jsc,
        .webkit_source_dir = engine.webkit_src,
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

/// The sysroot a build for `target` compiles and links against: COLLO_CXX_SYSROOT for a cross
/// build, none for the architecture running the build, as deps.zig and the build tool decide. One
/// environment then configures every step, so a sysroot exported for the aarch64 steps never
/// reaches the host's toolchain, engine or stamps.
pub fn cxxSysrootFor(b: *std.Build, opts: *const Options, target: std.Build.ResolvedTarget) []const u8 {
    return if (target.result.cpu.arch == b.graph.host.result.cpu.arch) "" else opts.cxx_sysroot;
}

pub const EngineDirs = struct {
    jsc: []const u8,
    webkit_src: []const u8,
};

/// The series addendum, under `runtime/patches/webkit/`, that the engine for `arch` applies after
/// the series, or null. Only an aarch64 engine under `16k` takes one, so the x86_64 engine and the
/// aarch64 `64k` engine build the series alone, in the directories and with the series hashes
/// they had before the option existed.
pub fn jscSeriesAddendum(arch: std.Target.Cpu.Arch, pages: Arm64Pages) ?[]const u8 {
    if (arch != .aarch64)
        return null;
    return switch (pages) {
        .@"16k" => arm64_pages16k_addendum,
        .@"64k" => null,
    };
}

/// The largest kernel page size the engine for `arch` and `pages` runs on, WTF's
/// `CeilingOnPageSize`, which `bindings.enginePageSizeCeiling` reads back from the engine.
pub fn jscPageSizeCeilingBytes(arch: std.Target.Cpu.Arch, pages: Arm64Pages) u64 {
    if (arch != .aarch64)
        return 4 * 1024;
    return switch (pages) {
        .@"16k" => 16 * 1024,
        .@"64k" => 64 * 1024,
    };
}

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
/// step pins a CPU model, plus -<addendum> when the engine applies a series
/// addendum, so engines built from different patch lists never share a
/// directory or a stamp.
pub fn jscProfileName(b: *std.Build, profile: JscProfile, mcpu: ?[]const u8, addendum: ?[]const u8) []const u8 {
    var name: []const u8 = @tagName(profile);
    if (mcpu) |cpu|
        name = b.fmt("{s}-{s}", .{ name, cpu });
    if (addendum) |series_addendum|
        name = b.fmt("{s}-{s}", .{ name, series_addendum });
    return name;
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
