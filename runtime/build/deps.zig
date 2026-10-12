//! The pinned dependencies as the build graph sees them: the steps over the
//! pristine trees (`deps-provision`, which fetches them, and the
//! verification every compilation of a tree read in place waits on), and
//! the native libraries the buildtool builds outside Zig's cache, ICU and
//! BoringSSL.
//!
//! Each native build owns one directory, `<root>/<triple>[-<mcpu>]`, and gets
//! exactly one step however many artifacts ask for it: two runs on one
//! directory clobber each other, and the build runner would otherwise run
//! them in parallel. `Native` keeps that one step per directory, which is
//! why the ICU mode is chosen once for the whole graph.

const std = @import("std");
const buildtool = @import("buildtool.zig");
const pins = @import("pins.zig");
const shims = @import("shims.zig");
const tool_mod = @import("tool.zig");
const toolchain_mod = @import("toolchain.zig");

/// The pin of `dependency`, read from its version file at configure time.
/// The text lives as long as the build graph.
pub fn loadPin(b: *std.Build, dependency: pins.Dependency) pins.Pin {
    const loaded = pins.load(b.allocator, b.build_root.handle, dependency) catch |err|
        std.process.fatal("cannot read the pin {s}/{s}: {s}", .{
            pins.deps_relative,
            pins.spec(dependency).version_file,
            @errorName(err),
        });
    return loaded.pin;
}

/// Fetches each of `dependencies` at its pin into `runtime/deps/`.
pub fn addProvisionStep(
    b: *std.Build,
    tool: *const tool_mod.Tool,
    name: []const u8,
    dependencies: []const pins.Dependency,
) *std.Build.Step.Run {
    const run = tool.addRun(b, name, "deps-provision");
    for (dependencies) |dependency|
        run.addArg(@tagName(dependency));
    return run;
}

/// What a native build is built for.
pub const Target = struct {
    target: std.Build.ResolvedTarget,
    /// The sysroot of a cross build. A build for the architecture running
    /// the build ignores it, so one set for a cross step never reaches the
    /// host's builds or their stamps.
    cxx_sysroot: []const u8,
    mcpu: ?[]const u8,
};

pub const Mode = enum {
    /// Build when the stamp does not admit the directory.
    build,
    /// Fail when the stamp does not admit the directory: under
    /// `-Djsc-prebuilt` the engine and the ICU it compiled against are
    /// admitted, never built.
    admit,
};

pub const Icu = struct {
    /// Absolute; holds `include/` and the archives `buildtool.icu_build.archives` names.
    prefix: []const u8,
    step: *std.Build.Step.Run,

    /// The installed headers, after the build that installs them.
    pub fn headers(icu: Icu, b: *std.Build) shims.HeaderDir {
        return .{ .path = b.pathJoin(&.{ icu.prefix, "include" }), .step = &icu.step.step };
    }

    /// The archives, in the order a link must name them.
    pub fn archives(icu: Icu, b: *std.Build) [buildtool.icu_build.archives.len][]const u8 {
        var paths: [buildtool.icu_build.archives.len][]const u8 = undefined;
        for (buildtool.icu_build.archives, 0..) |relative, index|
            paths[index] = b.pathJoin(&.{ icu.prefix, relative });
        return paths;
    }
};

pub const BoringSsl = struct {
    /// Absolute; the headers with Collo's series applied.
    include_dir: []const u8,
    /// Absolute; holds the archives `buildtool.boringssl_build.archives` names.
    lib_dir: []const u8,
    step: *std.Build.Step.Run,

    /// The archives, in the order a link must name them.
    pub fn archives(boringssl: BoringSsl, b: *std.Build) [buildtool.boringssl_build.archives.len][]const u8 {
        var paths: [buildtool.boringssl_build.archives.len][]const u8 = undefined;
        for (buildtool.boringssl_build.archives, 0..) |name, index|
            paths[index] = b.pathJoin(&.{ boringssl.lib_dir, name });
        return paths;
    }

    /// The patched headers, after the build that produces them.
    pub fn headers(boringssl: BoringSsl) shims.HeaderDir {
        return .{ .path = boringssl.include_dir, .step = &boringssl.step.step };
    }

    /// Links both archives into `compile`, an executable Zig links itself
    /// that uses TLS without the JSC bridge (stub-graph tests and benches).
    pub fn linkArchives(boringssl: BoringSsl, b: *std.Build, compile: *std.Build.Step.Compile) void {
        for (boringssl.archives(b)) |archive|
            compile.root_module.addObjectFile(.{ .cwd_relative = archive });
        compile.root_module.linkSystemLibrary("pthread", .{});
        compile.step.dependOn(&boringssl.step.step);
    }
};

/// The native builds of one build graph, one per directory.
pub const Native = struct {
    b: *std.Build,
    tool: *const tool_mod.Tool,
    /// Every ICU step's mode. One mode for the graph keeps one step per
    /// directory even when a dev step and a release step share a directory.
    icu_mode: Mode,
    icu_builds: std.StringArrayHashMapUnmanaged(Icu) = .empty,
    boringssl_builds: std.StringArrayHashMapUnmanaged(BoringSsl) = .empty,
    verify_step: ?*std.Build.Step.Run = null,

    pub fn create(b: *std.Build, tool: *const tool_mod.Tool, icu_mode: Mode) *Native {
        const native = b.allocator.create(Native) catch @panic("OOM");
        native.* = .{ .b = b, .tool = tool, .icu_mode = icu_mode };
        return native;
    }

    /// ICU for `target`. A cross build also builds ICU for the machine
    /// running the build, whose tools generate the cross build's data. The
    /// tool checks the ICU tree pristine at its pin itself, before and after
    /// it builds, so this step waits on no verification.
    pub fn icu(native: *Native, target: Target) Icu {
        const b = native.b;
        const triple = linuxTriple(b, target.target);
        const key = buildKey(b, triple, target.mcpu);
        if (native.icu_builds.get(key)) |existing|
            return existing;

        const cross = isCross(b, target);
        const host: ?Icu = if (cross)
            native.icu(.{ .target = b.graph.host, .cxx_sysroot = "", .mcpu = null })
        else
            null;

        const run = native.tool.addRun(b, b.fmt("icu {s}", .{key}), "icu-build");
        run.addArg(@tagName(native.icu_mode));
        run.addArg(triple);
        run.addArg(toolchain_mod.compilerRtArchName(target.target.result.cpu.arch));
        run.addArg(if (cross) target.cxx_sysroot else "");
        run.addArg(target.mcpu orelse "");
        run.addArg(if (cross) buildKey(b, linuxTriple(b, b.graph.host), null) else "");
        run.addArg(native.tool.identity);
        if (host) |host_icu|
            run.step.dependOn(&host_icu.step.step);

        const result: Icu = .{
            .prefix = b.pathFromRoot(b.fmt("{s}/{s}/install", .{ buildtool.icu_generated_relative, key })),
            .step = run,
        };
        native.icu_builds.put(b.allocator, key, result) catch @panic("OOM");
        return result;
    }

    /// BoringSSL for `target`, built or admitted by its stamp.
    pub fn boringssl(native: *Native, target: Target) BoringSsl {
        const b = native.b;
        const triple = linuxTriple(b, target.target);
        const key = buildKey(b, triple, target.mcpu);
        if (native.boringssl_builds.get(key)) |existing|
            return existing;

        const run = native.tool.addRun(b, b.fmt("boringssl {s}", .{key}), "boringssl-build");
        run.addArg(triple);
        run.addArg(toolchain_mod.compilerRtArchName(target.target.result.cpu.arch));
        run.addArg(if (isCross(b, target)) target.cxx_sysroot else "");
        run.addArg(target.mcpu orelse "");
        run.addArg(native.tool.identity);

        const root = b.pathFromRoot(b.fmt("{s}/{s}", .{ buildtool.boringssl_generated_relative, key }));
        const result: BoringSsl = .{
            .include_dir = b.pathJoin(&.{ root, "src", "include" }),
            .lib_dir = b.pathJoin(&.{ root, "build" }),
            .step = run,
        };
        native.boringssl_builds.put(b.allocator, key, result) catch @panic("OOM");
        return result;
    }

    /// The step that fails unless the trees the build compiles in place,
    /// the codecs and ls-hpack, are pristine at their pins. One step checks
    /// them all, once per build.
    pub fn verifyCompiledTrees(native: *Native) *std.Build.Step.Run {
        if (native.verify_step) |step|
            return step;
        const compiled_in_place = [_]pins.Dependency{ .ls_hpack, .zlib, .brotli, .zstd };
        const run = native.tool.addRun(native.b, "verify pinned trees", "deps-verify");
        for (compiled_in_place) |dependency|
            run.addArg(@tagName(dependency));
        native.verify_step = run;
        return run;
    }
};

/// The build tool decides cross by the same comparison, against the
/// architecture it runs on.
fn isCross(b: *std.Build, target: Target) bool {
    return target.target.result.cpu.arch != b.graph.host.result.cpu.arch;
}

fn linuxTriple(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    return target.result.linuxTriple(b.allocator) catch @panic("OOM");
}

fn buildKey(b: *std.Build, triple: []const u8, mcpu: ?[]const u8) []const u8 {
    return buildtool.nativeBuildKey(b.allocator, triple, mcpu orelse "") catch @panic("OOM");
}
