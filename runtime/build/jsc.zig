//! The engine steps: build or admit the pinned, patched WebKit/JSC, and the
//! patch-series operations around it. Every step runs the host buildtool
//! (build/buildtool.zig) under one of its subcommands; the clone itself is a
//! pinned tree that `deps-provision` fetches (deps.zig).
const std = @import("std");
const deps_mod = @import("deps.zig");
const pins = @import("pins.zig");
const tool_mod = @import("tool.zig");
const toolchain_mod = @import("toolchain.zig");

/// The WebKit pin from `runtime/deps/webkit.version`, read once per
/// configure; every engine step passes it to the tool.
pub fn expectedWebkitCommit(b: *std.Build) []const u8 {
    return deps_mod.loadPin(b, .webkit).commit;
}

pub const JscBuild = struct {
    /// The engine mode passed to CMake and prebuilt validation, not consumer optimization.
    cmake_build_type: []const u8,
    build_dir: []const u8,
    webkit_source_dir: []const u8,
    step: ?*std.Build.Step.Run,
};

pub const EngineInputs = struct {
    target: std.Build.ResolvedTarget,
    cmake_build_type: []const u8,
    jsc_build_dir: []const u8,
    webkit_source_dir: []const u8,
    cxx_sysroot: []const u8,
    mcpu: ?[]const u8,
    /// The ICU the engine compiles against. Its step runs first, because the
    /// engine's configure reads the headers that build installs.
    icu: deps_mod.Icu,
};

pub fn addBuildStep(b: *std.Build, tool: *const tool_mod.Tool, inputs: EngineInputs) *std.Build.Step.Run {
    return addEvidenceStep(b, tool, "build-webkit-jsc", "jsc-build", inputs);
}

pub fn addPrebuiltValidationStep(b: *std.Build, tool: *const tool_mod.Tool, inputs: EngineInputs) *std.Build.Step.Run {
    return addEvidenceStep(b, tool, "validate-webkit-jsc-prebuilt", "jsc-validate-prebuilt", inputs);
}

/// A patch-series operation, `webkit-authoring` or `webkit-export`. Each takes
/// only the pin; every path is derived from the repository root.
pub fn addWebkitStep(b: *std.Build, tool: *const tool_mod.Tool, subcommand: []const u8) *std.Build.Step.Run {
    const run = tool.addRun(b, subcommand, subcommand);
    run.addArg(expectedWebkitCommit(b));
    return run;
}

fn addEvidenceStep(
    b: *std.Build,
    tool: *const tool_mod.Tool,
    name: []const u8,
    subcommand: []const u8,
    inputs: EngineInputs,
) *std.Build.Step.Run {
    const run = tool.addRun(b, name, subcommand);
    run.addArg(inputs.jsc_build_dir);
    run.addArg(inputs.webkit_source_dir);
    run.addArg(inputs.target.result.linuxTriple(b.allocator) catch @panic("OOM"));
    run.addArg(toolchain_mod.compilerRtArchName(inputs.target.result.cpu.arch));
    run.addArg(inputs.cmake_build_type);
    run.addArg(inputs.cxx_sysroot);
    run.addArg(expectedWebkitCommit(b));
    run.addArg(inputs.mcpu orelse "");
    // Every source that interprets build provenance is hashed into the
    // identity, so a parser-only change cannot reuse a stamp produced under a
    // different evidence contract.
    run.addArg(tool.identity);
    run.addArg(inputs.icu.prefix);
    run.step.dependOn(&inputs.icu.step.step);
    return run;
}
