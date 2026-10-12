//! The build host tool (`buildtool.zig`) as the build graph sees it: one
//! compilation for the machine running the build, shared by every step that
//! runs it, and its identity, which every stamp the tool writes records so
//! that a change to the code interpreting provenance invalidates what it
//! admitted.

const std = @import("std");

pub const Tool = struct {
    executable: *std.Build.Step.Compile,
    /// SHA-256 over `identity_sources`, as lowercase hex.
    identity: []const u8,

    /// A run of `subcommand` from the repository root. The tool resolves
    /// every path from there, and it manages directories and stamps outside
    /// Zig's cache, so the run always executes and the tool decides whether
    /// there is work to do.
    pub fn addRun(tool: *const Tool, b: *std.Build, name: []const u8, subcommand: []const u8) *std.Build.Step.Run {
        const run = b.addRunArtifact(tool.executable);
        run.setName(name);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        run.addArg(subcommand);
        return run;
    }
};

/// The files whose bytes decide how the tool reads and writes provenance.
const identity_sources = [_][]const u8{
    "runtime/build/buildtool.zig",
    "runtime/build/pins.zig",
};

pub fn create(b: *std.Build) Tool {
    const executable = b.addExecutable(.{
        .name = "collo-buildtool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/build/buildtool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    return .{ .executable = executable, .identity = identity(b) };
}

fn identity(b: *std.Build) []const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("collo-jsc-build-tool-identity-v3\x00");
    for (identity_sources) |relative| {
        const bytes = b.build_root.handle.readFileAlloc(b.allocator, relative, 4 << 20) catch |err|
            std.process.fatal("cannot read build tool source '{s}': {s}", .{ relative, @errorName(err) });
        defer b.allocator.free(bytes);
        var path_len: [4]u8 = undefined;
        std.mem.writeInt(u32, &path_len, @intCast(relative.len), .big);
        hasher.update(&path_len);
        hasher.update(relative);
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
