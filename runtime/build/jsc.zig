//! The engine steps: build or admit the pinned, patched WebKit/JSC, and the
//! clone and patch-series operations around it. Every step runs the host
//! buildtool (build/buildtool.zig) under one of its subcommands; the archive
//! arch check is the pure `archiveMatchesArch` that tool exposes, reused here.
const std = @import("std");
const toolchain_mod = @import("toolchain.zig");

/// The pin lives with the other dependency pins, in runtime/deps/webkit.version, as a
/// `Commit: <sha1>` line. Read once per configure; every engine step passes it to the tool.
pub fn expectedWebkitCommit(b: *std.Build) []const u8 {
    const path = "runtime/deps/webkit.version";
    const text = b.build_root.handle.readFileAlloc(b.allocator, path, 64 * 1024) catch |err|
        std.process.fatal("cannot read the WebKit pin {s}: {s}", .{ path, @errorName(err) });
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const key = "Commit:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const commit = std.mem.trim(u8, line[key.len..], " \t\r");
        if (commit.len != 40) std.process.fatal("{s}: Commit must be a full 40-hex sha1, got '{s}'", .{ path, commit });
        for (commit) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c))
            std.process.fatal("{s}: Commit must be lowercase hex, got '{s}'", .{ path, commit });
        return commit;
    }
    std.process.fatal("{s}: no `Commit:` line", .{path});
}

pub const JscBuild = struct {
    /// The engine mode passed to CMake and prebuilt validation, not consumer optimization.
    cmake_build_type: []const u8,
    build_dir: []const u8,
    webkit_source_dir: []const u8,
    step: ?*std.Build.Step.Run,
};

pub fn addBuildStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    cmake_build_type: []const u8,
    jsc_build_dir: []const u8,
    webkit_source_dir: []const u8,
    cxx_sysroot: []const u8,
    mcpu: ?[]const u8,
) *std.Build.Step.Run {
    return addEvidenceStep(
        b,
        "build-webkit-jsc",
        "jsc-build",
        target,
        cmake_build_type,
        jsc_build_dir,
        webkit_source_dir,
        cxx_sysroot,
        mcpu,
    );
}

pub fn addPrebuiltValidationStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    cmake_build_type: []const u8,
    jsc_build_dir: []const u8,
    webkit_source_dir: []const u8,
    cxx_sysroot: []const u8,
    mcpu: ?[]const u8,
) *std.Build.Step.Run {
    return addEvidenceStep(
        b,
        "validate-webkit-jsc-prebuilt",
        "jsc-validate-prebuilt",
        target,
        cmake_build_type,
        jsc_build_dir,
        webkit_source_dir,
        cxx_sysroot,
        mcpu,
    );
}

/// A clone or patch-series operation: `webkit-provision`, `webkit-authoring` or
/// `webkit-export`. Each takes only the pin; every path is derived from the repository root.
pub fn addWebkitStep(b: *std.Build, subcommand: []const u8) *std.Build.Step.Run {
    const run = addToolRun(b, subcommand, subcommand);
    run.addArg(expectedWebkitCommit(b));
    return run;
}

fn addEvidenceStep(
    b: *std.Build,
    tool_name: []const u8,
    subcommand: []const u8,
    target: std.Build.ResolvedTarget,
    cmake_build_type: []const u8,
    jsc_build_dir: []const u8,
    webkit_source_dir: []const u8,
    cxx_sysroot: []const u8,
    mcpu: ?[]const u8,
) *std.Build.Step.Run {
    const run = addToolRun(b, tool_name, subcommand);
    run.addArg(jsc_build_dir);
    run.addArg(webkit_source_dir);
    run.addArg(target.result.linuxTriple(b.allocator) catch @panic("OOM"));
    run.addArg(toolchain_mod.compilerRtArchName(target.result.cpu.arch));
    run.addArg(cmake_build_type);
    run.addArg(cxx_sysroot);
    run.addArg(expectedWebkitCommit(b));
    run.addArg(mcpu orelse "");
    // Hash every source that interprets build provenance, so a parser-only
    // change cannot reuse a stamp produced under a different evidence contract.
    run.addArg(toolIdentity(b));
    return run;
}

fn addToolRun(b: *std.Build, tool_name: []const u8, subcommand: []const u8) *std.Build.Step.Run {
    const tool = b.addExecutable(.{
        .name = tool_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/build/buildtool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(tool);
    // The tool resolves every path from realpath("."), so it must run from the
    // build root; and it manages directories and stamps outside zig's cache, so
    // it always runs and self-short-circuits rather than being cached by zig.
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.addArg(subcommand);
    return run;
}

fn toolIdentity(b: *std.Build) []const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("collo-jsc-build-tool-identity-v2\x00");
    for ([_][]const u8{
        "runtime/build/buildtool.zig",
    }) |rel| {
        const bytes = b.build_root.handle.readFileAlloc(b.allocator, rel, 4 << 20) catch |err|
            std.process.fatal("cannot read JSC build tool source '{s}': {s}", .{ rel, @errorName(err) });
        defer b.allocator.free(bytes);
        var path_len: [4]u8 = undefined;
        std.mem.writeInt(u32, &path_len, @intCast(rel.len), .big);
        hasher.update(&path_len);
        hasher.update(rel);
        var source_len: [8]u8 = undefined;
        std.mem.writeInt(u64, &source_len, bytes.len, .big);
        hasher.update(&source_len);
        hasher.update(bytes);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return b.dupe(&hex);
}
