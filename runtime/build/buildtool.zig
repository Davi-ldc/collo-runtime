//! Single Collo build host tool. `main` dispatches on argv[1]:
//!   webkit-provision      clone oven-sh/WebKit at the pin into runtime/deps/WebKit
//!   jsc-build             build the pinned, patched WebKit/JSC into runtime/deps/jsc-build
//!   jsc-validate-prebuilt admit an existing engine build by its provenance, never build
//!   webkit-authoring      create the patch-authoring worktree with the series applied
//!   webkit-export         regenerate runtime/patches/webkit from the authoring branch
//!   apply-patches         apply a <dep>/*.patch series to a private copy of a dep
//!
//! Every engine directory lives under the project's `runtime/deps`, so the tool
//! never deletes anything outside that tree. Only the Zig std library is used;
//! external programs (git, cmake, ninja, patch) are spawned via
//! std.process.Child with explicit argv arrays, never a shell, and every spawn
//! has its exit status checked. Builds are serialized by rule, not by lock:
//! two invocations on one engine directory clobber each other.
const std = @import("std");

fn pathContainsTraversal(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".."))
            return true;
    }
    return false;
}

fn assertDirectPhysicalRegularDescriptor(path: []const u8, descriptor: std.posix.fd_t) !void {
    if (!std.fs.path.isAbsolute(path) or pathContainsTraversal(path))
        return error.NonCanonicalPath;
    const metadata = try std.posix.fstat(descriptor);
    if (!std.posix.S.ISREG(metadata.mode))
        return error.NotDirectRegularFile;
    if (metadata.nlink != 1)
        return error.MultipleHardLinks;
    var descriptor_path_buffer: [64]u8 = undefined;
    const descriptor_path = try std.fmt.bufPrint(
        &descriptor_path_buffer,
        "/proc/self/fd/{d}",
        .{descriptor},
    );
    var physical_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const physical_path = try std.fs.cwd().realpath(descriptor_path, &physical_path_buffer);
    if (!std.mem.eql(u8, path, physical_path))
        return error.NonCanonicalPath;
}

fn openDirectRegularFileNoLinks(path: []const u8) !std.fs.File {
    if (!std.fs.path.isAbsolute(path) or pathContainsTraversal(path))
        return error.NonCanonicalPath;
    const descriptor = try std.posix.open(path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0);
    errdefer std.posix.close(descriptor);
    try assertDirectPhysicalRegularDescriptor(path, descriptor);
    return .{ .handle = descriptor };
}

/// Where the engine lives, relative to the project root. The clone is read-only input; the
/// worktree and build directories under `engine_generated_relative` are recreated by the tool.
pub const webkit_repository_relative = "runtime/deps/WebKit";
pub const webkit_authoring_relative = "runtime/deps/webkit-authoring";
pub const engine_generated_relative = "runtime/deps/jsc-build";
pub const webkit_patches_relative = "runtime/patches/webkit";

pub const JscBuildPaths = struct {
    repository: []const u8,
    worktree: []const u8,
    build: []const u8,
    project_root: []const u8,
};

/// The repository must be the project's pinned clone, and both generated directories must lie
/// strictly under the project's engine-generated root and apart from each other. That bound is
/// what makes `rm -rf` of a generated directory safe: nothing outside it can be named.
pub fn validateJscBuildPaths(paths: JscBuildPaths) !void {
    try requireCanonicalDirectoryAncestors(paths.project_root);
    try requireCanonicalDirectoryAncestors(paths.repository);
    var repository_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const expected_repository = std.fmt.bufPrint(
        &repository_buffer,
        "{s}/{s}",
        .{ paths.project_root, webkit_repository_relative },
    ) catch return error.NonCanonicalPath;
    if (!std.mem.eql(u8, paths.repository, expected_repository))
        return error.EngineRepositoryPath;

    var generated_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const generated_root = std.fmt.bufPrint(
        &generated_buffer,
        "{s}/{s}",
        .{ paths.project_root, engine_generated_relative },
    ) catch return error.NonCanonicalPath;
    const generated = [_][]const u8{ paths.worktree, paths.build };
    for (generated) |path| {
        try requireCanonicalDirectoryAncestors(path);
        if (std.mem.eql(u8, path, generated_root) or !pathIsWithin(path, generated_root))
            return error.GeneratedPathOutsideEngineRoot;
    }
    if (pathsOverlap(paths.worktree, paths.build))
        return error.OverlappingJscPaths;
}

fn pathsOverlap(lhs: []const u8, rhs: []const u8) bool {
    return pathIsWithin(lhs, rhs) or pathIsWithin(rhs, lhs);
}

fn pathIsWithin(path: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, path, parent))
        return true;
    if (!std.mem.startsWith(u8, path, parent))
        return false;
    return parent.len == 1 or path[parent.len] == std.fs.path.sep;
}

/// Missing suffixes are allowed; every existing ancestor must be a physical directory.
fn requireCanonicalDirectoryAncestors(path: []const u8) !void {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes or
        !std.fs.path.isAbsolute(path) or pathContainsTraversal(path))
        return error.NonCanonicalPath;
    if (std.mem.indexOf(u8, path, "//") != null or
        (path.len > 1 and path[path.len - 1] == std.fs.path.sep))
        return error.NonCanonicalPath;
    var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "."))
            return error.NonCanonicalPath;
    }

    var prefix = path;
    var physical_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (0..path.len) |_| {
        const metadata = std.posix.fstatat(
            std.posix.AT.FDCWD,
            prefix,
            std.posix.AT.SYMLINK_NOFOLLOW,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                prefix = std.fs.path.dirname(prefix) orelse return err;
                continue;
            },
            else => return err,
        };
        if (std.posix.S.ISLNK(metadata.mode))
            return error.NonCanonicalPath;
        if (!std.posix.S.ISDIR(metadata.mode))
            return error.NotDirectory;
        const physical = try std.fs.cwd().realpath(prefix, &physical_buffer);
        if (!std.mem.eql(u8, prefix, physical))
            return error.NonCanonicalPath;
        return;
    }
    return error.NonCanonicalPath;
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    if (argv.len < 2) {
        printErr("usage: {s} <{s}> ...\n", .{ argv[0], subcommand_list });
        std.process.exit(64);
    }

    // Re-base argv so each subcommand sees its own positional args exactly as
    // the standalone tools did: sub_argv[0] is the subcommand name (used only in
    // usage/error text, in place of the old argv[0]) and sub_argv[1..] are the
    // subcommand's arguments. sub_argv aliases into argv; main owns and frees argv.
    const sub = argv[1];
    const sub_argv = argv[1..];

    if (std.mem.eql(u8, sub, "jsc-build")) {
        // jsc-build handles its own expected failures via fail(); a genuine
        // abort (e.g. OOM) bubbles out here.
        jsc_build.run(gpa, sub_argv) catch |err| {
            printErr("collo build_jsc: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "jsc-validate-prebuilt")) {
        jsc_build.validatePrebuilt(gpa, sub_argv) catch |err| {
            printErr("collo validate JSC prebuilt: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "webkit-provision")) {
        webkit_ops.provision(gpa, sub_argv) catch |err| {
            printErr("collo webkit-provision: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "webkit-authoring")) {
        webkit_ops.authoring(gpa, sub_argv) catch |err| {
            printErr("collo webkit-authoring: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "webkit-export")) {
        webkit_ops.exportSeries(gpa, sub_argv) catch |err| {
            printErr("collo webkit-export: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "apply-patches")) {
        return apply_patches.run(gpa, sub_argv);
    }
    printErr("unknown subcommand '{s}' (expected {s})\n", .{ sub, subcommand_list });
    std.process.exit(64);
}

const subcommand_list = "webkit-provision|jsc-build|jsc-validate-prebuilt|webkit-authoring|webkit-export|apply-patches";

/// printErr writes a diagnostic to stderr (buffered, then flushed). Shared by
/// main and jsc_build.fail.
fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;
    stderr.print(fmt, args) catch |err| switch (err) {
        error.WriteFailed => return,
    };
    stderr.flush() catch |err| switch (err) {
        error.WriteFailed => return,
    };
}

// =============================================================================
// jsc-build: build the pinned, patched WebKit/JSC into runtime/deps/jsc-build.
// =============================================================================

pub const jsc_cmake_profile_args = [_][]const u8{
    "-DPORT=JSCOnly",
    "-DENABLE_STATIC_JSC=ON",
    "-DUSE_THIN_ARCHIVES=OFF",
    "-DUSE_BUN_JSC_ADDITIONS=ON",
    "-DEVENT_LOOP_TYPE=Generic",
    "-DUSE_BUN_EVENT_LOOP=OFF",
    "-DUSE_EXTERNAL_MIMALLOC=OFF",
    "-DUSE_SYSTEM_MALLOC=OFF",
    "-DENABLE_REMOTE_INSPECTOR=OFF",
    "-DENABLE_API_TESTS=ON",
    "-DENABLE_JAVASCRIPT_SHELL=OFF",
    "-DENABLE_TOOLS=OFF",
};

pub fn validateJscCmakeProfile(cache: []const u8) !void {
    if (std.mem.indexOfAny(u8, cache, "\r\x00") != null)
        return error.MalformedCmakeCache;
    inline for (jsc_cmake_profile_args) |argument| {
        const equals = comptime std.mem.indexOfScalar(u8, argument, '=').?;
        try jsc_build.requireCmakeCacheValue(cache, argument[2..equals], argument[equals + 1 ..]);
    }
}

pub const validateJscBuildNinja = jsc_build.validateBuildNinjaContents;

const jsc_build = struct {
    const Sha256 = std.crypto.hash.sha2.Sha256;

    // Positions are relative to sub_argv[0], which names the producer or validator.
    const arg_jsc_build_dir = 1;
    const arg_webkit_worktree = 2;
    const arg_target_triple = 3;
    const arg_target_arch = 4;
    const arg_cmake_build_type = 5;
    const arg_cxx_sysroot = 6;
    const arg_expected_commit = 7;
    const arg_mcpu = 8;
    const arg_tool_identity = 9;
    const arg_count_required = 10;

    const stamp_schema = "collo-jsc-stamp-v3";
    const attestation_schema = "collo-jsc-attestation-v2";
    const stamp_filename = ".collo-jsc.stamp";
    const attestation_filename = ".collo-jsc.attestation.v2";

    const BuildAttestationInputs = struct {
        expected_commit: []const u8,
        patch_hash: []const u8,
        target_triple: []const u8,
        target_arch: []const u8,
        cmake_build_type: []const u8,
        cxx_sysroot: []const u8,
        mcpu: []const u8,
        compiler_version: []const u8,
        tool_identity: []const u8,
    };

    // Maximum bytes for files we read fully into memory (patches, overlay
    // sources, the stamp). WebKit patches and overlay sources are well under this.
    const file_read_max = 64 * 1024 * 1024;
    pub fn run(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        return runImpl(gpa, argv, false);
    }

    pub fn validatePrebuilt(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        return runImpl(gpa, argv, true);
    }

    fn runImpl(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        validate_prebuilt_only: bool,
    ) !void {
        if (argv.len != arg_count_required) {
            fail(argv, 1, "usage: {s} <jsc_build_dir> <webkit_worktree> <target_triple> " ++
                "<target_arch> <cmake_build_type> <cxx_sysroot> <expected_commit> " ++
                "<mcpu> <tool_identity>\n", .{argv[0]});
        }

        const target_triple = argv[arg_target_triple];
        const target_arch = argv[arg_target_arch];
        const cmake_build_type = argv[arg_cmake_build_type];
        const cxx_sysroot = argv[arg_cxx_sysroot];
        const expected_commit = argv[arg_expected_commit];
        const mcpu = argv[arg_mcpu];
        const tool_identity = argv[arg_tool_identity];

        const repo_root = try resolveRepoRoot(gpa, argv);
        defer gpa.free(repo_root);

        const jsc_build_dir = try absolutize(gpa, repo_root, argv[arg_jsc_build_dir]);
        defer gpa.free(jsc_build_dir);
        const webkit_worktree = try absolutize(gpa, repo_root, argv[arg_webkit_worktree]);
        defer gpa.free(webkit_worktree);
        const webkit_repo = try std.fs.path.join(gpa, &.{ repo_root, webkit_repository_relative });
        defer gpa.free(webkit_repo);
        validateJscBuildPaths(.{
            .repository = webkit_repo,
            .worktree = webkit_worktree,
            .build = jsc_build_dir,
            .project_root = repo_root,
        }) catch |err| fail(argv, 1, "invalid runtime JSC paths: {s}\n", .{@errorName(err)});

        const patch_dir = try std.fs.path.join(gpa, &.{ repo_root, webkit_patches_relative });
        defer gpa.free(patch_dir);
        const stamp_path = try std.fs.path.join(gpa, &.{ jsc_build_dir, stamp_filename });
        defer gpa.free(stamp_path);
        const attestation_path = try std.fs.path.join(gpa, &.{ jsc_build_dir, attestation_filename });
        defer gpa.free(attestation_path);

        try checkRequiredCommands(gpa, argv);
        try checkWebkitCheckout(gpa, argv, webkit_repo, expected_commit);

        // The series is the depth-1 `patches/webkit/*.patch` set, LC_ALL=C
        // sorted. The pinned commit plus that series is the whole engine.
        const series = try sortedPatchFiles(gpa, argv, patch_dir);
        defer {
            for (series) |path| gpa.free(path);
            gpa.free(series);
        }

        const patch_hash = try hashPatchSeries(gpa, argv, repo_root, series);
        defer gpa.free(patch_hash);
        const compiler_version = try clangVersionFirstLine(gpa, argv);
        defer gpa.free(compiler_version);
        const attestation_inputs = BuildAttestationInputs{
            .expected_commit = expected_commit,
            .patch_hash = patch_hash,
            .target_triple = target_triple,
            .target_arch = target_arch,
            .cmake_build_type = cmake_build_type,
            .cxx_sysroot = cxx_sysroot,
            .mcpu = mcpu,
            .compiler_version = compiler_version,
            .tool_identity = tool_identity,
        };

        if (validate_prebuilt_only) {
            if (!try isUpToDate(
                gpa,
                argv,
                jsc_build_dir,
                webkit_worktree,
                attestation_inputs,
            )) {
                fail(
                    argv,
                    1,
                    "selected JSC prebuilt is stale or has incomplete provenance: {s}\n",
                    .{jsc_build_dir},
                );
            }
            try stdoutPrint(argv, "JSC prebuilt provenance verified: {s}\n", .{jsc_build_dir});
            return;
        }

        // Up-to-date means the canonical stamp and attestation reconstruct from
        // the current inputs, CMake graph, and archive bytes.
        if (try isUpToDate(gpa, argv, jsc_build_dir, webkit_worktree, attestation_inputs)) {
            try stdoutPrint(argv, "JSC up to date: {s}\n", .{jsc_build_dir});
            return;
        }

        try recreateWorktree(gpa, argv, webkit_repo, webkit_worktree, jsc_build_dir, expected_commit);
        try materializeSparseBuildSource(gpa, argv, webkit_worktree);
        try requireWebkitBuildSource(argv, webkit_worktree);

        try applyPatchSeries(gpa, argv, webkit_worktree, series);
        try requireWebkitBuildSource(argv, webkit_worktree);

        try runCmakeConfigure(gpa, argv, webkit_worktree, jsc_build_dir, .{
            .cmake_build_type = cmake_build_type,
            .target_arch = target_arch,
            .target_triple = target_triple,
            .cxx_sysroot = cxx_sysroot,
            .mcpu = mcpu,
        });
        try requireWebkitBuildSource(argv, webkit_worktree);
        validateCmakeConfiguration(gpa, jsc_build_dir, webkit_worktree, attestation_inputs) catch |err|
            fail(argv, 1, "generated JSC configuration is invalid: {s}\n", .{@errorName(err)});
        validateBuildNinja(gpa, jsc_build_dir, cmake_build_type) catch |err|
            fail(argv, 1, "generated JSC build graph is invalid: {s}\n", .{@errorName(err)});
        try runCmakeBuild(gpa, argv, jsc_build_dir);

        try checkArchiveArch(gpa, argv, jsc_build_dir, target_arch);
        var evidence = buildEvidence(
            gpa,
            jsc_build_dir,
            webkit_worktree,
            attestation_inputs,
        ) catch |err| fail(argv, 1, "cannot construct JSC build attestation: {s}\n", .{@errorName(err)});
        defer evidence.deinit(gpa);
        try writeTextAtomic(gpa, argv, attestation_path, evidence.attestation_text);
        const attestation_sha = sha256TextWithTrailingNewline(evidence.attestation_text);
        const stamp_text = try buildStampText(gpa, attestation_inputs, &attestation_sha);
        defer gpa.free(stamp_text);
        try writeTextAtomic(gpa, argv, stamp_path, stamp_text);
        try stdoutPrint(argv, "JSC built: {s}\n", .{jsc_build_dir});
    }

    /// The physical (symlink-resolved) project root, which is the tool's working directory.
    /// std.fs.cwd()'s fd is AT_FDCWD, which realpath cannot resolve through /proc/self/fd,
    /// so "." is opened for a real fd first; getcwd and PWD are the fallbacks for
    /// filesystems where /proc/self/fd cannot be resolved.
    fn resolveRepoRoot(gpa: std.mem.Allocator, argv: [][:0]u8) ![]u8 {
        var cwd_dir = std.fs.cwd().openDir(".", .{}) catch |err|
            fail(argv, 1, "cannot open current directory: {s}\n", .{@errorName(err)});
        defer cwd_dir.close();
        return cwd_dir.realpathAlloc(gpa, ".") catch
            std.process.getCwdAlloc(gpa) catch
            std.process.getEnvVarOwned(gpa, "PWD") catch |err|
            fail(argv, 1, "cannot resolve current directory: {s}\n", .{@errorName(err)});
    }

    /// fail writes a diagnostic to stderr and exits with `code`. It never returns.
    fn fail(argv: [][:0]u8, code: u8, comptime fmt: []const u8, args: anytype) noreturn {
        // argv is owned by main()'s gpa; std.process.exit bypasses that deinit (no
        // leak check runs), so a free here buys nothing — and freeing with the
        // wrong allocator (it was page_allocator) panics with incorrect alignment.
        _ = argv;
        printErr(fmt, args);
        std.process.exit(code);
    }

    /// absolutize returns `path` unchanged if absolute, else joins it onto
    /// repo_root — mirroring the old script's `case "$x" in /*) ... *) repo/$x`.
    fn absolutize(gpa: std.mem.Allocator, repo_root: []const u8, path: []const u8) ![]u8 {
        if (pathContainsTraversal(path))
            return error.PathTraversal;
        if (std.fs.path.isAbsolute(path))
            return std.fs.path.resolve(gpa, &.{path});
        return std.fs.path.resolve(gpa, &.{ repo_root, path });
    }

    fn stdoutPrint(argv: [][:0]u8, comptime fmt: []const u8, args: anytype) !void {
        _ = argv;
        var buffer: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&buffer);
        const stdout = &stdout_writer.interface;
        try stdout.print(fmt, args);
        try stdout.flush();
    }

    // --- preflight checks ----------------------------------------------------

    /// checkRequiredCommands ensures git, cmake, ninja and the clang-19 toolchain
    /// pieces resolve on PATH. Hashing, locking, file walking and the
    /// archive/ELF parse are native Zig, and CMake's archiver is driven through
    /// the clang-19 toolchain, not a system `ar`.
    fn checkRequiredCommands(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        const commands = [_][]const u8{
            "git", "cmake", "ninja", "clang-19", "clang++-19",
        };
        for (commands) |command| {
            if (!commandExists(gpa, command))
                fail(argv, 1, "missing required command: {s}\n", .{command});
        }
    }

    /// commandExists resolves `command` against each PATH entry, mirroring
    /// `command -v` for plain command names: the candidate must exist AND be
    /// executable (X_OK), exactly as `command -v`/PATH lookup requires — a readable
    /// but non-executable file is not a command. Returns false if PATH is unset.
    /// std.posix.access takes a slice and null-terminates it internally, so the
    /// joined (non-null-terminated) path is safe to pass.
    fn commandExists(gpa: std.mem.Allocator, command: []const u8) bool {
        const path_value = std.process.getEnvVarOwned(gpa, "PATH") catch return false;
        defer gpa.free(path_value);

        var entries = std.mem.splitScalar(u8, path_value, ':');
        while (entries.next()) |dir| {
            if (dir.len == 0)
                continue;
            const candidate = std.fs.path.join(gpa, &.{ dir, command }) catch return false;
            defer gpa.free(candidate);
            std.posix.access(candidate, std.posix.X_OK) catch continue;
            return true;
        }
        return false;
    }

    /// The runtime source must be a standalone checkout whose HEAD is the pinned commit.
    fn checkWebkitCheckout(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        webkit_repo: []const u8,
        expected_commit: []const u8,
    ) !void {
        const jsc_source = try std.fs.path.join(gpa, &.{ webkit_repo, "Source/JavaScriptCore" });
        defer gpa.free(jsc_source);
        std.fs.cwd().access(jsc_source, .{}) catch
            fail(argv, 1, "missing runtime WebKit source: {s}\n", .{webkit_repo});
        const git_directory = try std.fs.path.join(gpa, &.{ webkit_repo, ".git" });
        defer gpa.free(git_directory);
        var metadata = std.fs.cwd().openDir(git_directory, .{ .no_follow = true }) catch
            fail(argv, 1, "runtime WebKit must own its git directory: {s}\n", .{webkit_repo});
        defer metadata.close();
        const common_directory = gitCapture(gpa, &.{
            "git", "-C", webkit_repo, "rev-parse", "--path-format=absolute", "--git-common-dir",
        }) catch null;
        defer if (common_directory) |value| gpa.free(value);
        const common_text = if (common_directory) |value|
            std.mem.trim(u8, value, " \t\r\n")
        else
            "<unknown>";
        if (!std.mem.eql(u8, common_text, git_directory))
            fail(argv, 1, "runtime WebKit shares git metadata with another checkout: {s}\n", .{webkit_repo});

        // Compare the checkout root literally to reject symlink aliases.
        const toplevel = gitCapture(gpa, &.{
            "git", "-C", webkit_repo, "rev-parse", "--show-toplevel",
        }) catch null;
        const toplevel_ok = if (toplevel) |value| blk: {
            defer gpa.free(value);
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            break :blk std.mem.eql(u8, trimmed, webkit_repo);
        } else false;
        if (!toplevel_ok) {
            fail(argv, 1, "runtime WebKit is not a standalone git checkout: {s}\n", .{webkit_repo});
        }

        // HEAD must equal the pin, not merely contain it. Worktrees materialize committed objects,
        // so uncommitted source edits cannot reach the build.
        const head = gitCapture(gpa, &.{ "git", "-C", webkit_repo, "rev-parse", "HEAD" }) catch null;
        defer if (head) |value| gpa.free(value);
        const head_text = if (head) |value| std.mem.trim(u8, value, " \t\r\n") else "<unknown>";
        if (!std.mem.eql(u8, head_text, expected_commit)) {
            fail(argv, 1, "runtime WebKit checkout {s} is not at the pinned commit {s}; " ++
                "current HEAD is {s}\n", .{ webkit_repo, expected_commit, head_text });
        }
    }

    // --- patch series --------------------------------------------------------

    /// sortedPatchFiles returns absolute paths to the depth-1 `*.patch` files
    /// in `dir`, byte-lexicographically sorted (LC_ALL=C) — that order is the
    /// apply order and the order the series hash sees. A missing directory
    /// yields an empty series. The caller owns the slice and every path in it.
    fn sortedPatchFiles(gpa: std.mem.Allocator, argv: [][:0]u8, dir: []const u8) ![][]u8 {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path|
                gpa.free(path);
            paths.deinit(gpa);
        }

        var handle = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return paths.toOwnedSlice(gpa), // missing dir: empty.
            else => fail(argv, 1, "cannot open patch directory {s}: {s}\n", .{ dir, @errorName(err) }),
        };
        defer handle.close();

        var it = handle.iterate();
        while (it.next() catch |err|
            fail(argv, 1, "cannot read patch directory {s}: {s}\n", .{ dir, @errorName(err) })) |entry|
        {
            if (!std.mem.endsWith(u8, entry.name, ".patch"))
                continue;
            if (entry.kind != .file)
                fail(argv, 1, "patch-series entry is not a direct regular file: {s}/{s}\n", .{ dir, entry.name });
            const full = try std.fs.path.join(gpa, &.{ dir, entry.name });
            try paths.append(gpa, full);
        }

        std.mem.sort([]u8, paths.items, {}, lessThanBytes);
        return paths.toOwnedSlice(gpa);
    }

    fn lessThanBytes(_: void, lhs: []u8, rhs: []u8) bool {
        return std.mem.order(u8, lhs, rhs) == .lt;
    }

    /// hashPatchSeries reproduces `(cd repo && sha256sum <patches>) | sha256sum`:
    /// for each patch in order it hashes its bytes, formats GNU coreutils' line
    /// "<hex>  <path>\n" with the path relative to the repository root, feeds
    /// that line into the outer hash, and returns the outer digest as a
    /// lowercase hex string (caller owns). The relative path is what keeps the
    /// attestation independent of where the checkout lives: a prebuilt made
    /// from one clone is the same engine from any other clone of the same tree.
    fn hashPatchSeries(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        repo_root: []const u8,
        files: []const []u8,
    ) ![]u8 {
        var outer: Sha256 = Sha256.init(.{});
        for (files) |path| {
            const bytes = std.fs.cwd().readFileAlloc(gpa, path, file_read_max) catch |err|
                fail(argv, 1, "cannot read patch {s}: {s}\n", .{ path, @errorName(err) });
            defer gpa.free(bytes);

            var inner: Sha256 = Sha256.init(.{});
            inner.update(bytes);
            var inner_digest: [Sha256.digest_length]u8 = undefined;
            inner.final(&inner_digest);
            const inner_hex = std.fmt.bytesToHex(inner_digest, .lower);

            const relative = try std.fs.path.relative(gpa, repo_root, path);
            defer gpa.free(relative);
            // GNU `sha256sum` prints "<hash>  <path>\n" (two spaces, binary mode
            // would use " *"; coreutils default text mode uses two spaces).
            const line = try std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ inner_hex, relative });
            defer gpa.free(line);
            outer.update(line);
        }
        var outer_digest: [Sha256.digest_length]u8 = undefined;
        outer.final(&outer_digest);
        const outer_hex = std.fmt.bytesToHex(outer_digest, .lower);
        return gpa.dupe(u8, &outer_hex);
    }

    /// clangVersionFirstLine returns the first line of `clang-19 --version`,
    /// matching `clang-19 --version | sed -n '1p'`.
    fn clangVersionFirstLine(gpa: std.mem.Allocator, argv: [][:0]u8) ![]u8 {
        const out = gitCapture(gpa, &.{ "clang-19", "--version" }) catch |err|
            fail(argv, 1, "cannot run clang-19 --version: {s}\n", .{@errorName(err)});
        defer gpa.free(out);
        const newline = std.mem.indexOfScalar(u8, out, '\n');
        const first = if (newline) |index| out[0..index] else out;
        // Strip a trailing CR so the field is byte-identical to sed's output.
        const trimmed = std.mem.trimRight(u8, first, "\r");
        return gpa.dupe(u8, trimmed);
    }

    // --- up-to-date check ----------------------------------------------------

    const FileDigest = struct {
        sha256: [Sha256.digest_length * 2]u8,
        size: u64,
    };

    const BuildEvidence = struct {
        attestation_text: []u8,

        fn deinit(evidence: *BuildEvidence, gpa: std.mem.Allocator) void {
            gpa.free(evidence.attestation_text);
            evidence.* = undefined;
        }
    };

    const DirectFileBytes = struct {
        bytes: []u8,
        digest: FileDigest,

        fn deinit(value: *DirectFileBytes, gpa: std.mem.Allocator) void {
            gpa.free(value.bytes);
            value.* = undefined;
        }
    };

    /// The static archives the JSC build publishes, in the order the
    /// attestation records them.
    const archive_outputs = [_][]const u8{
        "lib/libJavaScriptCore.a",
        "lib/libWTF.a",
        "lib/libbmalloc.a",
    };

    const OpenedArchiveSet = struct {
        files: [archive_outputs.len]std.fs.File,
        digests: [archive_outputs.len]FileDigest,

        fn deinit(archives: *OpenedArchiveSet) void {
            for (archives.files) |file| file.close();
            archives.* = undefined;
        }
    };

    fn directRegularFile(path: []const u8) bool {
        const file = openDirectRegularFileNoLinks(path) catch return false;
        file.close();
        return true;
    }

    fn digestRegularFile(path: []const u8) !FileDigest {
        const file = try openDirectRegularFileNoLinks(path);
        defer file.close();
        const stat = try file.stat();
        if (stat.kind != .file)
            return error.NotDirectRegularFile;
        var hasher: Sha256 = Sha256.init(.{});
        var buffer: [1024 * 1024]u8 = undefined;
        while (true) {
            const count = try file.read(&buffer);
            if (count == 0)
                break;
            hasher.update(buffer[0..count]);
        }
        var digest: [Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        return .{
            .sha256 = std.fmt.bytesToHex(digest, .lower),
            .size = stat.size,
        };
    }

    fn digestBytes(bytes: []const u8) FileDigest {
        var hasher: Sha256 = Sha256.init(.{});
        hasher.update(bytes);
        var digest: [Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        return .{
            .sha256 = std.fmt.bytesToHex(digest, .lower),
            .size = bytes.len,
        };
    }

    fn digestBorrowedRegularFile(file: std.fs.File, size: u64) !FileDigest {
        var hasher: Sha256 = Sha256.init(.{});
        var buffer: [1024 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < size) {
            const want: usize = @intCast(@min(size - offset, buffer.len));
            const count = try file.pread(buffer[0..want], offset);
            if (count == 0)
                return error.UnexpectedEndOfFile;
            hasher.update(buffer[0..count]);
            offset += count;
        }
        var digest: [Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        return .{
            .sha256 = std.fmt.bytesToHex(digest, .lower),
            .size = size,
        };
    }

    fn openArchiveSet(
        gpa: std.mem.Allocator,
        jsc_build_dir: []const u8,
    ) !OpenedArchiveSet {
        var result: OpenedArchiveSet = undefined;
        var opened: usize = 0;
        errdefer for (result.files[0..opened]) |file| file.close();
        for (archive_outputs, 0..) |relative, index| {
            const path = try std.fs.path.join(gpa, &.{ jsc_build_dir, relative });
            defer gpa.free(path);
            const file = try openDirectRegularFileNoLinks(path);
            result.files[index] = file;
            opened += 1;
            const stat = try file.stat();
            if (stat.kind != .file)
                return error.NotDirectRegularFile;
            result.digests[index] = try digestBorrowedRegularFile(file, stat.size);
        }
        return result;
    }

    fn validateArchivePathsStillReferenceOpenFiles(
        gpa: std.mem.Allocator,
        jsc_build_dir: []const u8,
        archives: *const OpenedArchiveSet,
    ) !void {
        for (archive_outputs, 0..) |relative, index| {
            const path = try std.fs.path.join(gpa, &.{ jsc_build_dir, relative });
            defer gpa.free(path);
            const current = try openDirectRegularFileNoLinks(path);
            defer current.close();
            const expected_stat = try archives.files[index].stat();
            const current_stat = try current.stat();
            if (expected_stat.kind != .file or current_stat.kind != .file or
                current_stat.inode != expected_stat.inode or
                current_stat.size != expected_stat.size or
                current_stat.mode != expected_stat.mode or
                current_stat.mtime != expected_stat.mtime or
                current_stat.ctime != expected_stat.ctime)
            {
                return error.ArchiveChanged;
            }
        }
    }

    fn readDirectRegularFileAlloc(
        gpa: std.mem.Allocator,
        path: []const u8,
        maximum: usize,
    ) ![]u8 {
        const file = try openDirectRegularFileNoLinks(path);
        defer file.close();
        return file.readToEndAlloc(gpa, maximum);
    }

    fn readDirectRegularFileEvidence(
        gpa: std.mem.Allocator,
        path: []const u8,
        maximum: usize,
    ) !DirectFileBytes {
        const file = try openDirectRegularFileNoLinks(path);
        defer file.close();
        const before = try file.stat();
        if (before.kind != .file or before.size > maximum)
            return error.NotDirectRegularFile;
        const bytes = try file.readToEndAlloc(gpa, maximum);
        errdefer gpa.free(bytes);
        const after = try file.stat();
        if (after.kind != .file or after.inode != before.inode or
            after.size != before.size or after.mode != before.mode or
            after.mtime != before.mtime or after.ctime != before.ctime or
            bytes.len != before.size)
        {
            return error.FileChangedDuringRead;
        }
        return .{ .bytes = bytes, .digest = digestBytes(bytes) };
    }

    fn cmakeCacheValue(cache: []const u8, key: []const u8) !?[]const u8 {
        var found: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, cache, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//"))
                continue;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const colon = std.mem.indexOfScalar(u8, line[0..equals], ':') orelse continue;
            if (!std.mem.eql(u8, line[0..colon], key))
                continue;
            if (found != null)
                return error.DuplicateCmakeCacheKey;
            found = line[equals + 1 ..];
        }
        return found;
    }

    fn requireCmakeCacheValue(cache: []const u8, key: []const u8, expected: []const u8) !void {
        const actual = try cmakeCacheValue(cache, key) orelse
            return error.MissingCmakeCacheKey;
        if (!std.mem.eql(u8, actual, expected))
            return error.CmakeCacheValueMismatch;
    }

    fn requireEmptyCmakeCacheValue(cache: []const u8, key: []const u8) !void {
        if (try cmakeCacheValue(cache, key)) |actual| {
            if (actual.len != 0)
                return error.CmakeCacheValueMismatch;
        }
    }

    fn resolveCommandPath(gpa: std.mem.Allocator, command: []const u8) ![]u8 {
        const path_value = try std.process.getEnvVarOwned(gpa, "PATH");
        defer gpa.free(path_value);
        var entries = std.mem.splitScalar(u8, path_value, ':');
        while (entries.next()) |directory| {
            if (directory.len == 0)
                continue;
            const candidate = try std.fs.path.join(gpa, &.{ directory, command });
            defer gpa.free(candidate);
            std.posix.access(candidate, std.posix.X_OK) catch continue;
            return std.fs.cwd().realpathAlloc(gpa, candidate);
        }
        return error.CommandNotFound;
    }

    fn validateCmakeConfiguration(
        gpa: std.mem.Allocator,
        jsc_build_dir: []const u8,
        webkit_worktree: []const u8,
        inputs: BuildAttestationInputs,
    ) !void {
        const cache_path = try std.fs.path.join(gpa, &.{ jsc_build_dir, "CMakeCache.txt" });
        defer gpa.free(cache_path);
        var evidence = try readDirectRegularFileEvidence(gpa, cache_path, 64 * 1024 * 1024);
        defer evidence.deinit(gpa);
        return validateCmakeConfigurationContents(
            gpa,
            evidence.bytes,
            webkit_worktree,
            inputs,
        );
    }

    fn validateCmakeConfigurationContents(
        gpa: std.mem.Allocator,
        cache: []const u8,
        webkit_worktree: []const u8,
        inputs: BuildAttestationInputs,
    ) !void {
        try validateJscCmakeProfile(cache);
        try requireCmakeCacheValue(cache, "CMAKE_BUILD_TYPE", inputs.cmake_build_type);
        try requireCmakeCacheValue(cache, "CMAKE_HOME_DIRECTORY", webkit_worktree);
        try requireCmakeCacheValue(cache, "CMAKE_GENERATOR", "Ninja");

        const expected_c = try resolveCommandPath(gpa, "clang-19");
        defer gpa.free(expected_c);
        const expected_cxx = try resolveCommandPath(gpa, "clang++-19");
        defer gpa.free(expected_cxx);
        const actual_c_text = try cmakeCacheValue(cache, "CMAKE_C_COMPILER") orelse
            return error.MissingCmakeCacheKey;
        const actual_cxx_text = try cmakeCacheValue(cache, "CMAKE_CXX_COMPILER") orelse
            return error.MissingCmakeCacheKey;
        const actual_c = try std.fs.cwd().realpathAlloc(gpa, actual_c_text);
        defer gpa.free(actual_c);
        const actual_cxx = try std.fs.cwd().realpathAlloc(gpa, actual_cxx_text);
        defer gpa.free(actual_cxx);
        if (!std.mem.eql(u8, actual_c, expected_c) or !std.mem.eql(u8, actual_cxx, expected_cxx))
            return error.CmakeCompilerMismatch;

        const expected_flags = if (inputs.mcpu.len == 0)
            ""
        else
            try std.fmt.allocPrint(gpa, "-mcpu={s}", .{inputs.mcpu});
        defer if (inputs.mcpu.len != 0) gpa.free(expected_flags);
        try requireCmakeCacheValue(cache, "CMAKE_C_FLAGS", expected_flags);
        try requireCmakeCacheValue(cache, "CMAKE_CXX_FLAGS", expected_flags);

        if (std.mem.eql(u8, inputs.target_arch, "aarch64") and !hostIsAarch64()) {
            if (inputs.cxx_sysroot.len == 0)
                return error.MissingCrossSysroot;
            try requireCmakeCacheValue(cache, "CMAKE_SYSROOT", inputs.cxx_sysroot);
            try requireCmakeCacheValue(cache, "CMAKE_C_COMPILER_TARGET", inputs.target_triple);
            try requireCmakeCacheValue(cache, "CMAKE_CXX_COMPILER_TARGET", inputs.target_triple);
            try requireCmakeCacheValue(cache, "CMAKE_SYSTEM_NAME", "Linux");
            try requireCmakeCacheValue(cache, "CMAKE_SYSTEM_PROCESSOR", "aarch64");
        } else {
            if (inputs.cxx_sysroot.len != 0)
                return error.UnexpectedNativeSysroot;
            try requireEmptyCmakeCacheValue(cache, "CMAKE_SYSROOT");
            try requireEmptyCmakeCacheValue(cache, "CMAKE_C_COMPILER_TARGET");
            try requireEmptyCmakeCacheValue(cache, "CMAKE_CXX_COMPILER_TARGET");
        }
    }

    const NinjaInputClass = enum {
        explicit,
        implicit,
        order_only,
        validation,
    };

    const NinjaInputScan = struct {
        /// Only explicit inputs enter the archive command through Ninja's `$in` variable.
        object_prefix: []const u8,
        object_count: usize = 0,
    };

    fn scanNinjaInputs(dependencies: []const u8, scan: *NinjaInputScan) !void {
        var input_class: NinjaInputClass = .explicit;
        var tokens = std.mem.splitScalar(u8, dependencies, ' ');
        while (tokens.next()) |token| {
            if (token.len == 0)
                continue;
            if (std.mem.eql(u8, token, "|")) {
                if (input_class != .explicit)
                    return error.BuildNinjaContractMismatch;
                input_class = .implicit;
                continue;
            }
            if (std.mem.eql(u8, token, "||")) {
                if (input_class != .explicit and input_class != .implicit)
                    return error.BuildNinjaContractMismatch;
                input_class = .order_only;
                continue;
            }
            if (std.mem.eql(u8, token, "|@")) {
                if (input_class == .validation)
                    return error.BuildNinjaContractMismatch;
                input_class = .validation;
                continue;
            }
            if (input_class != .explicit)
                continue;
            if (std.mem.startsWith(u8, token, scan.object_prefix) and
                std.mem.endsWith(u8, token, ".o"))
            {
                scan.object_count += 1;
            }
        }
    }

    fn validateBuildNinja(
        gpa: std.mem.Allocator,
        jsc_build_dir: []const u8,
        cmake_build_type: []const u8,
    ) !void {
        const path = try std.fs.path.join(gpa, &.{ jsc_build_dir, "build.ninja" });
        defer gpa.free(path);
        const contents = try readDirectRegularFileAlloc(gpa, path, 512 * 1024 * 1024);
        defer gpa.free(contents);
        return validateBuildNinjaContents(contents, cmake_build_type);
    }

    /// Each archive needs one link edge, one alias, and explicit objects from every required
    /// CMake target. JavaScriptCore directly archives its own sources and the LLInt object library.
    /// The rules file must be included exactly once.
    fn validateBuildNinjaContents(
        contents: []const u8,
        cmake_build_type: []const u8,
    ) !void {
        if (contents.len == 0)
            return error.MalformedBuildNinja;
        if (contents[contents.len - 1] != '\n')
            return error.MalformedBuildNinja;
        if (std.mem.indexOfAny(u8, contents, "\r\x00") != null)
            return error.MalformedBuildNinja;

        const ArchiveSpec = struct {
            output: []const u8,
            alias: []const u8,
            rule_prefix: []const u8,
            object_prefixes: []const []const u8,
        };
        const specs = [_]ArchiveSpec{
            .{
                .output = archive_outputs[0],
                .alias = "JavaScriptCore",
                .rule_prefix = "CXX_STATIC_LIBRARY_LINKER__JavaScriptCore_",
                .object_prefixes = &.{
                    "Source/JavaScriptCore/CMakeFiles/JavaScriptCore.dir/",
                    "Source/JavaScriptCore/CMakeFiles/LowLevelInterpreterLib.dir/",
                },
            },
            .{
                .output = archive_outputs[1],
                .alias = "WTF",
                .rule_prefix = "CXX_STATIC_LIBRARY_LINKER__WTF_",
                .object_prefixes = &.{"Source/WTF/wtf/CMakeFiles/WTF.dir/"},
            },
            .{
                .output = archive_outputs[2],
                .alias = "bmalloc",
                .rule_prefix = "CXX_STATIC_LIBRARY_LINKER__bmalloc_",
                .object_prefixes = &.{"Source/bmalloc/CMakeFiles/bmalloc.dir/"},
            },
        };
        var archive_counts = [_]usize{0} ** specs.len;
        var alias_counts = [_]usize{0} ** specs.len;
        var include_count: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or std.ascii.isWhitespace(line[0]))
                continue;
            if (std.mem.eql(u8, line, "include CMakeFiles/rules.ninja")) {
                include_count += 1;
                continue;
            }
            if (!std.mem.startsWith(u8, line, "build "))
                continue;
            const colon = std.mem.indexOfScalarPos(u8, line, "build ".len, ':') orelse
                return error.BuildNinjaContractMismatch;
            const outputs = line["build ".len..colon];
            const right = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (right.len == 0)
                return error.BuildNinjaContractMismatch;
            const rule_end = std.mem.indexOfScalar(u8, right, ' ') orelse right.len;
            const rule = right[0..rule_end];
            const dependencies = if (rule_end == right.len)
                ""
            else
                std.mem.trimLeft(u8, right[rule_end + 1 ..], " ");

            for (specs, 0..) |spec, index| {
                if (std.mem.eql(u8, outputs, spec.output)) {
                    for (spec.object_prefixes) |prefix| {
                        var scan: NinjaInputScan = .{ .object_prefix = prefix };
                        try scanNinjaInputs(dependencies, &scan);
                        if (scan.object_count == 0)
                            return error.BuildNinjaContractMismatch;
                    }
                    var expected_rule_buffer: [128]u8 = undefined;
                    const expected_rule = std.fmt.bufPrint(
                        &expected_rule_buffer,
                        "{s}{s}",
                        .{ spec.rule_prefix, cmake_build_type },
                    ) catch return error.BuildNinjaContractMismatch;
                    if (!std.mem.eql(u8, rule, expected_rule))
                        return error.BuildNinjaContractMismatch;
                    archive_counts[index] += 1;
                }
                if (std.mem.eql(u8, outputs, spec.alias)) {
                    var expected_alias_buffer: [128]u8 = undefined;
                    const expected_alias = std.fmt.bufPrint(
                        &expected_alias_buffer,
                        "phony {s}",
                        .{spec.output},
                    ) catch return error.BuildNinjaContractMismatch;
                    if (!std.mem.eql(u8, right, expected_alias))
                        return error.BuildNinjaContractMismatch;
                    alias_counts[index] += 1;
                }
            }
        }
        if (include_count != 1)
            return error.BuildNinjaContractMismatch;
        for (archive_counts, alias_counts) |archive_count, alias_count| {
            if (archive_count != 1 or alias_count != 1)
                return error.BuildNinjaContractMismatch;
        }
    }

    fn sha256TextWithTrailingNewline(text_bytes: []const u8) [Sha256.digest_length * 2]u8 {
        var hasher: Sha256 = Sha256.init(.{});
        hasher.update(text_bytes);
        hasher.update("\n");
        var digest: [Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    fn buildStampText(
        gpa: std.mem.Allocator,
        inputs: BuildAttestationInputs,
        attestation_sha256: []const u8,
    ) ![]u8 {
        try validateCanonicalInputs(inputs);
        try validateCanonicalField(attestation_sha256);
        return std.fmt.allocPrint(gpa, "schema={s}\n" ++
            "commit={s}\n" ++
            "patch_hash={s}\n" ++
            "target_triple={s}\n" ++
            "target_arch={s}\n" ++
            "cmake_build_type={s}\n" ++
            "cxx_sysroot={s}\n" ++
            "mcpu={s}\n" ++
            "compiler={s}\n" ++
            "script_sha={s}\n" ++
            "attestation_sha256={s}", .{
            stamp_schema,
            inputs.expected_commit,
            inputs.patch_hash,
            inputs.target_triple,
            inputs.target_arch,
            inputs.cmake_build_type,
            inputs.cxx_sysroot,
            inputs.mcpu,
            inputs.compiler_version,
            inputs.tool_identity,
            attestation_sha256,
        });
    }

    fn buildEvidence(
        gpa: std.mem.Allocator,
        jsc_build_dir: []const u8,
        webkit_worktree: []const u8,
        inputs: BuildAttestationInputs,
    ) !BuildEvidence {
        try validateCanonicalInputs(inputs);
        try validateCanonicalField(webkit_worktree);
        const cmake_cache_path = try std.fs.path.join(gpa, &.{ jsc_build_dir, "CMakeCache.txt" });
        defer gpa.free(cmake_cache_path);
        const build_ninja_path = try std.fs.path.join(gpa, &.{ jsc_build_dir, "build.ninja" });
        defer gpa.free(build_ninja_path);
        var cmake_cache_evidence = try readDirectRegularFileEvidence(
            gpa,
            cmake_cache_path,
            64 * 1024 * 1024,
        );
        defer cmake_cache_evidence.deinit(gpa);
        try validateCmakeConfigurationContents(
            gpa,
            cmake_cache_evidence.bytes,
            webkit_worktree,
            inputs,
        );
        const cmake_cache = cmake_cache_evidence.digest;
        var build_ninja_evidence = try readDirectRegularFileEvidence(
            gpa,
            build_ninja_path,
            512 * 1024 * 1024,
        );
        defer build_ninja_evidence.deinit(gpa);
        try validateBuildNinjaContents(build_ninja_evidence.bytes, inputs.cmake_build_type);
        const build_ninja = build_ninja_evidence.digest;

        var archives = try openArchiveSet(gpa, jsc_build_dir);
        defer archives.deinit();
        const jsc_archive = archives.digests[0];
        const wtf_archive = archives.digests[1];
        const bmalloc_archive = archives.digests[2];

        var attestation_output: std.Io.Writer.Allocating = .init(gpa);
        errdefer attestation_output.deinit();
        const attestation_writer = &attestation_output.writer;
        try attestation_writer.print("schema={s}\n" ++
            "commit={s}\npatch_hash={s}\n" ++
            "target_triple={s}\ntarget_arch={s}\ncmake_build_type={s}\n" ++
            "cxx_sysroot={s}\nmcpu={s}\ncompiler={s}\nscript_sha={s}\n" ++
            "webkit_worktree={s}\n", .{
            attestation_schema,
            inputs.expected_commit,
            inputs.patch_hash,
            inputs.target_triple,
            inputs.target_arch,
            inputs.cmake_build_type,
            inputs.cxx_sysroot,
            inputs.mcpu,
            inputs.compiler_version,
            inputs.tool_identity,
            webkit_worktree,
        });
        try attestation_writer.print("cmake_cache_sha256={s}\ncmake_cache_size={d}\n" ++
            "build_ninja_sha256={s}\nbuild_ninja_size={d}\n" ++
            "libJavaScriptCore_sha256={s}\nlibJavaScriptCore_size={d}\n" ++
            "libWTF_sha256={s}\nlibWTF_size={d}\n" ++
            "libbmalloc_sha256={s}\nlibbmalloc_size={d}", .{
            cmake_cache.sha256,
            cmake_cache.size,
            build_ninja.sha256,
            build_ninja.size,
            jsc_archive.sha256,
            jsc_archive.size,
            wtf_archive.sha256,
            wtf_archive.size,
            bmalloc_archive.sha256,
            bmalloc_archive.size,
        });
        const attestation_text = try attestation_output.toOwnedSlice();
        errdefer gpa.free(attestation_text);
        try validateArchivePathsStillReferenceOpenFiles(gpa, jsc_build_dir, &archives);
        return .{ .attestation_text = attestation_text };
    }

    fn canonicalTextMatches(gpa: std.mem.Allocator, path: []const u8, expected: []const u8) bool {
        const file = openDirectRegularFileNoLinks(path) catch return false;
        defer file.close();
        const actual = file.readToEndAlloc(gpa, file_read_max) catch return false;
        defer gpa.free(actual);
        return actual.len == expected.len + 1 and std.mem.eql(u8, actual[0..expected.len], expected) and actual[actual.len - 1] == '\n';
    }

    fn directRegularFileMtime(path: []const u8) ?i128 {
        const file = openDirectRegularFileNoLinks(path) catch return null;
        defer file.close();
        const metadata = file.stat() catch return null;
        if (metadata.kind != .file)
            return null;
        return metadata.mtime;
    }

    fn relativeDirectRegularFileMtime(
        gpa: std.mem.Allocator,
        root: []const u8,
        relative: []const u8,
    ) !?i128 {
        const path = try std.fs.path.join(gpa, &.{ root, relative });
        defer gpa.free(path);
        return directRegularFileMtime(path);
    }

    fn validateCanonicalInputs(inputs: BuildAttestationInputs) !void {
        inline for (.{
            inputs.expected_commit,
            inputs.patch_hash,
            inputs.target_triple,
            inputs.target_arch,
            inputs.cmake_build_type,
            inputs.cxx_sysroot,
            inputs.mcpu,
            inputs.compiler_version,
            inputs.tool_identity,
        }) |value| try validateCanonicalField(value);
    }

    fn validateCanonicalField(value: []const u8) !void {
        if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null)
            return error.InvalidCanonicalField;
    }

    fn isUpToDate(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        jsc_build_dir: []const u8,
        webkit_worktree: []const u8,
        inputs: BuildAttestationInputs,
    ) !bool {
        var evidence = buildEvidence(gpa, jsc_build_dir, webkit_worktree, inputs) catch return false;
        defer evidence.deinit(gpa);
        const attestation_path = try std.fs.path.join(gpa, &.{ jsc_build_dir, attestation_filename });
        defer gpa.free(attestation_path);
        if (!canonicalTextMatches(gpa, attestation_path, evidence.attestation_text))
            return false;
        const attestation_sha = sha256TextWithTrailingNewline(evidence.attestation_text);
        const stamp_text = try buildStampText(gpa, inputs, &attestation_sha);
        defer gpa.free(stamp_text);
        const stamp_path = try std.fs.path.join(gpa, &.{ jsc_build_dir, stamp_filename });
        defer gpa.free(stamp_path);
        if (!canonicalTextMatches(gpa, stamp_path, stamp_text))
            return false;

        // Publication chronology is part of the contract: every hashed input
        // predates the attestation that records it, which predates the stamp
        // that seals it. Without this a byte-identical but newer input would
        // pass here and then be rejected by the consumer.
        const attestation_mtime = directRegularFileMtime(attestation_path) orelse return false;
        const stamp_mtime = directRegularFileMtime(stamp_path) orelse return false;
        if (attestation_mtime > stamp_mtime)
            return false;
        const cmake_mtime = try relativeDirectRegularFileMtime(gpa, jsc_build_dir, "CMakeCache.txt") orelse return false;
        if (cmake_mtime > attestation_mtime)
            return false;
        inline for (.{"build.ninja"} ++ archive_outputs) |relative| {
            const input_mtime = try relativeDirectRegularFileMtime(gpa, jsc_build_dir, relative) orelse return false;
            if (input_mtime > attestation_mtime)
                return false;
        }

        try checkArchiveArch(gpa, argv, jsc_build_dir, inputs.target_arch);
        return true;
    }

    // --- worktree + sources --------------------------------------------------

    /// recreateWorktree prunes any stale worktree registration, removes the
    /// existing worktree dir, deletes the build dir, prunes again, then adds a
    /// detached worktree at the pinned commit — the script's recreate sequence.
    fn recreateWorktree(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        webkit_repo: []const u8,
        webkit_worktree: []const u8,
        jsc_build_dir: []const u8,
        expected_commit: []const u8,
    ) !void {
        if (std.fs.path.dirname(webkit_worktree)) |parent|
            std.fs.cwd().makePath(parent) catch |err|
                fail(argv, 1, "cannot create {s}: {s}\n", .{ parent, @errorName(err) });
        if (std.fs.path.dirname(jsc_build_dir)) |parent|
            std.fs.cwd().makePath(parent) catch |err|
                fail(argv, 1, "cannot create {s}: {s}\n", .{ parent, @errorName(err) });

        // Best-effort prune (the script ignores its failure).
        _ = gitSucceeds(gpa, &.{ "git", "-C", webkit_repo, "worktree", "prune" });

        // Try `git worktree remove --force --force`; if that fails, rm -rf the
        // worktree dir when it still exists — mirroring the script's fallback.
        const removed = gitSucceeds(gpa, &.{
            "git",    "-C",      webkit_repo, "worktree",
            "remove", "--force", "--force",   webkit_worktree,
        });
        if (!removed) {
            if (try pathEntryExists(webkit_worktree)) {
                std.fs.cwd().deleteTree(webkit_worktree) catch |err|
                    fail(argv, 1, "cannot remove worktree {s}: {s}\n", .{ webkit_worktree, @errorName(err) });
            }
        }

        // rm -rf the build dir unconditionally.
        std.fs.cwd().deleteTree(jsc_build_dir) catch |err|
            fail(argv, 1, "cannot remove build dir {s}: {s}\n", .{ jsc_build_dir, @errorName(err) });

        _ = gitSucceeds(gpa, &.{ "git", "-C", webkit_repo, "worktree", "prune" });

        // The add must succeed (the script has no `|| true` here).
        // `--no-checkout`, because materializeSparseBuildSource narrows the cone right after and a
        // normal add would write all 871 MB before there was anywhere to say we did not want it.
        try gitMustSucceed(gpa, argv, &.{
            "git",           "-C",      webkit_repo, "worktree", "add",
            "--no-checkout", "--force", "--force",   "--detach", webkit_worktree,
            expected_commit,
        });
    }

    fn materializeSparseBuildSource(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        webkit_worktree: []const u8,
    ) !void {
        // Only the header-map script is needed from Tools; ensureHeaderMapTool supplies it.
        try gitMustSucceed(gpa, argv, &.{
            "git",                        "-C",
            webkit_worktree,              "sparse-checkout",
            "set",                        "--cone",
            "Source/cmake",               "Source/JavaScriptCore",
            "Source/WTF",                 "Source/bmalloc",
            "Source/ThirdParty/capstone", "Source/ThirdParty/unifdef",
            "Source/ThirdParty/gtest",
        });
        try gitMustSucceed(gpa, argv, &.{ "git", "-C", webkit_worktree, "checkout" });
    }

    /// requireWebkitBuildSource asserts the build-source files the script checks
    /// are present in the worktree.
    fn requireWebkitBuildSource(argv: [][:0]u8, webkit_worktree: []const u8) !void {
        const required = [_][]const u8{
            "Source/JavaScriptCore/offlineasm/generate_settings_extractor.rb",
            "Source/JavaScriptCore/llint/LowLevelInterpreter.asm",
        };
        for (required) |relative| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ webkit_worktree, relative }) catch
                fail(argv, 1, "path too long: {s}/{s}\n", .{ webkit_worktree, relative });
            std.fs.cwd().access(full, .{}) catch
                fail(argv, 1, "missing required WebKit build source: {s}\n", .{full});
        }
    }

    // --- patch application ---------------------------------------------------

    /// applyPatchSeries applies each patch via `git apply --check --whitespace=
    /// error` then `git apply --whitespace=error`, both of which must succeed.
    fn applyPatchSeries(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        webkit_worktree: []const u8,
        files: []const []u8,
    ) !void {
        for (files) |patch| {
            try gitMustSucceed(gpa, argv, &.{
                "git", "-C", webkit_worktree, "apply", "--check", "--whitespace=error", patch,
            });
            try gitMustSucceed(gpa, argv, &.{
                "git", "-C", webkit_worktree, "apply", "--whitespace=error", patch,
            });
        }
    }

    // --- cmake ---------------------------------------------------------------

    const CmakeSpec = struct {
        cmake_build_type: []const u8,
        target_arch: []const u8,
        target_triple: []const u8,
        cxx_sysroot: []const u8,
        mcpu: []const u8,
    };

    /// The sparse source omits Tools; extract its pinned header-map script into the build directory.
    fn ensureHeaderMapTool(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        webkit_worktree: []const u8,
        jsc_build_dir: []const u8,
    ) ![]u8 {
        const tools_dir = try std.fmt.allocPrint(gpa, "{s}/collo-tools", .{jsc_build_dir});
        errdefer gpa.free(tools_dir);

        const scripts_dir = try std.fmt.allocPrint(gpa, "{s}/Scripts", .{tools_dir});
        defer gpa.free(scripts_dir);
        std.fs.cwd().makePath(scripts_dir) catch |err|
            fail(argv, 1, "cannot create {s}: {s}\n", .{ scripts_dir, @errorName(err) });

        const source = try gitCapture(gpa, &.{ "git", "-C", webkit_worktree, "show", "HEAD:Tools/Scripts/hmaptool" });
        defer gpa.free(source);

        const tool_path = try std.fmt.allocPrint(gpa, "{s}/hmaptool", .{scripts_dir});
        defer gpa.free(tool_path);
        const file = std.fs.cwd().createFile(tool_path, .{ .mode = 0o755 }) catch |err|
            fail(argv, 1, "cannot write {s}: {s}\n", .{ tool_path, @errorName(err) });
        defer file.close();
        file.writeAll(source) catch |err|
            fail(argv, 1, "cannot write {s}: {s}\n", .{ tool_path, @errorName(err) });

        return tools_dir;
    }

    fn runCmakeConfigure(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        webkit_worktree: []const u8,
        jsc_build_dir: []const u8,
        spec: CmakeSpec,
    ) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);

        const build_type_arg = try std.fmt.allocPrint(gpa, "-DCMAKE_BUILD_TYPE={s}", .{spec.cmake_build_type});
        defer gpa.free(build_type_arg);

        const tools_dir = try ensureHeaderMapTool(gpa, argv, webkit_worktree, jsc_build_dir);
        defer gpa.free(tools_dir);
        const tools_dir_arg = try std.fmt.allocPrint(gpa, "-DTOOLS_DIR={s}", .{tools_dir});
        defer gpa.free(tools_dir_arg);

        try args.appendSlice(gpa, &.{
            "cmake", "-S", webkit_worktree, "-B", jsc_build_dir, "-G", "Ninja",
        });
        try args.appendSlice(gpa, &.{
            build_type_arg,
            "-DCMAKE_C_COMPILER=clang-19",
            "-DCMAKE_CXX_COMPILER=clang++-19",
            tools_dir_arg,
        });
        try args.appendSlice(gpa, &jsc_cmake_profile_args);

        var c_flags_arg: ?[]u8 = null;
        var cxx_flags_arg: ?[]u8 = null;
        defer if (c_flags_arg) |arg| gpa.free(arg);
        defer if (cxx_flags_arg) |arg| gpa.free(arg);
        if (spec.mcpu.len > 0) {
            c_flags_arg = try std.fmt.allocPrint(gpa, "-DCMAKE_C_FLAGS=-mcpu={s}", .{spec.mcpu});
            cxx_flags_arg = try std.fmt.allocPrint(gpa, "-DCMAKE_CXX_FLAGS=-mcpu={s}", .{spec.mcpu});
            try args.append(gpa, c_flags_arg.?);
            try args.append(gpa, cxx_flags_arg.?);
        }

        var sysroot_arg: ?[]u8 = null;
        var c_target_arg: ?[]u8 = null;
        var cxx_target_arg: ?[]u8 = null;
        defer if (sysroot_arg) |arg| gpa.free(arg);
        defer if (c_target_arg) |arg| gpa.free(arg);
        defer if (cxx_target_arg) |arg| gpa.free(arg);
        if (std.mem.eql(u8, spec.target_arch, "aarch64") and !hostIsAarch64()) {
            if (spec.cxx_sysroot.len == 0) {
                fail(argv, 1, "cross-compiling ARM WebKit/JSC requires " ++
                    "COLLO_CXX_SYSROOT=<aarch64 sysroot>\n", .{});
            }
            sysroot_arg = try std.fmt.allocPrint(gpa, "-DCMAKE_SYSROOT={s}", .{spec.cxx_sysroot});
            c_target_arg = try std.fmt.allocPrint(gpa, "-DCMAKE_C_COMPILER_TARGET={s}", .{spec.target_triple});
            cxx_target_arg = try std.fmt.allocPrint(gpa, "-DCMAKE_CXX_COMPILER_TARGET={s}", .{spec.target_triple});
            try args.appendSlice(gpa, &.{
                "-DCMAKE_SYSTEM_NAME=Linux",
                "-DCMAKE_SYSTEM_PROCESSOR=aarch64",
                sysroot_arg.?,
                c_target_arg.?,
                cxx_target_arg.?,
                // The host GNU ld only carries x86 emulations; lld is
                // multi-target by construction, so every cross link (cmake's
                // try_compile probes included) must go through it.
                "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld",
                "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld",
                "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld",
            });
        }

        try spawnMustSucceed(gpa, argv, args.items);
    }

    /// JSC's unified sources can consume multiple GiB each, so the default job count is memory-aware.
    /// API tests are configured on Linux but do not belong to the archive target's dependencies.
    fn runCmakeBuild(gpa: std.mem.Allocator, argv: [][:0]u8, jsc_build_dir: []const u8) !void {
        const parallel = buildJobCount(gpa);
        const parallel_arg = try std.fmt.allocPrint(gpa, "{d}", .{parallel});
        defer gpa.free(parallel_arg);
        try spawnMustSucceed(gpa, argv, &.{
            "cmake",      "--build",    jsc_build_dir, "--target", "JavaScriptCore",
            "--parallel", parallel_arg,
        });
    }

    fn buildJobCount(gpa: std.mem.Allocator) usize {
        const cpu_count = blk: {
            const n = std.Thread.getCpuCount() catch 4;
            break :blk if (n == 0) 4 else n;
        };
        if (std.process.getEnvVarOwned(gpa, "COLLO_BUILD_JOBS")) |value| {
            defer gpa.free(value);
            if (std.fmt.parseInt(usize, std.mem.trim(u8, value, " \t\r\n"), 10)) |n| {
                if (n >= 1) return n;
            } else |_| {}
        } else |_| {}
        const mem_gib = totalMemoryGiB() orelse return cpu_count;
        const mem_jobs = @max(@as(usize, 2), mem_gib / 3);
        return @min(cpu_count, mem_jobs);
    }

    /// Reads MemTotal from /proc/meminfo, in GiB. Null if it cannot be read.
    fn totalMemoryGiB() ?usize {
        var buffer: [4096]u8 = undefined;
        const file = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return null;
        defer file.close();
        const len = file.read(&buffer) catch return null;
        const contents = buffer[0..len];
        const key = "MemTotal:";
        const start = std.mem.indexOf(u8, contents, key) orelse return null;
        var rest: []const u8 = contents[start + key.len ..];
        rest = std.mem.trimLeft(u8, rest, " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
        const kib = std.fmt.parseInt(usize, rest[0..end], 10) catch return null;
        return kib / (1024 * 1024);
    }

    fn hostIsAarch64() bool {
        return @import("builtin").target.cpu.arch == .aarch64;
    }

    // --- archive arch check --------------------------------------------------

    /// checkArchiveArch delegates to the shared archiveMatchesArch on
    /// <jsc_build_dir>/lib/libJavaScriptCore.a, failing fatally on mismatch — the
    /// same contract as the script's check_jsc_archive.sh invocations.
    fn checkArchiveArch(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        jsc_build_dir: []const u8,
        target_arch: []const u8,
    ) !void {
        const lib = try std.fs.path.join(gpa, &.{ jsc_build_dir, "lib/libJavaScriptCore.a" });
        defer gpa.free(lib);
        const matches = archiveMatchesArch(gpa, lib, target_arch) catch |err|
            fail(argv, 1, "failed to validate JSC archive architecture: {s}\n", .{@errorName(err)});
        if (!matches)
            fail(argv, 1, "JSC archive '{s}' does not match target arch {s}\n", .{ lib, target_arch });
    }

    // --- stamp ---------------------------------------------------------------

    fn writeTextAtomic(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        path: []const u8,
        text_bytes: []const u8,
    ) !void {
        return writeBytesAtomic(gpa, argv, path, text_bytes, true);
    }

    /// Write one record atomically. Builds on one directory never run concurrently, so the
    /// fixed sibling temporary name is exclusive; rename publishes only fully synced bytes.
    fn writeBytesAtomic(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        path: []const u8,
        bytes: []const u8,
        append_newline: bool,
    ) !void {
        _ = gpa;
        const parent_path = std.fs.path.dirname(path) orelse ".";
        const basename = std.fs.path.basename(path);
        var parent = std.fs.cwd().openDir(parent_path, .{ .no_follow = true, .iterate = true }) catch |err|
            fail(argv, 1, "cannot open atomic-write parent {s}: {s}\n", .{ parent_path, @errorName(err) });
        defer parent.close();
        var temporary_buffer: [std.fs.max_name_bytes]u8 = undefined;
        const temporary_name = std.fmt.bufPrint(&temporary_buffer, ".{s}.tmp", .{basename}) catch
            fail(argv, 1, "atomic-write basename is too long: {s}\n", .{basename});
        parent.deleteFile(temporary_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => fail(argv, 1, "cannot remove stale atomic-write temporary {s}: {s}\n", .{ temporary_name, @errorName(err) }),
        };
        errdefer parent.deleteFile(temporary_name) catch {};
        var file = parent.createFile(temporary_name, .{
            .truncate = true,
            .exclusive = true,
            .mode = 0o600,
        }) catch |err|
            fail(argv, 1, "cannot create atomic-write temporary {s}: {s}\n", .{ temporary_name, @errorName(err) });
        var file_open = true;
        defer if (file_open) file.close();
        std.posix.fchmod(file.handle, 0o600) catch |err|
            fail(argv, 1, "cannot set private mode on atomic-write temporary {s}: {s}\n", .{ temporary_name, @errorName(err) });
        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&buffer);
        const writer = &file_writer.interface;
        writer.writeAll(bytes) catch |err|
            fail(argv, 1, "cannot write canonical bytes {s}: {s}\n", .{ temporary_name, @errorName(err) });
        if (append_newline) writer.writeByte('\n') catch |err|
            fail(argv, 1, "cannot terminate canonical text {s}: {s}\n", .{ temporary_name, @errorName(err) });
        writer.flush() catch |err|
            fail(argv, 1, "cannot flush canonical text {s}: {s}\n", .{ temporary_name, @errorName(err) });
        file.sync() catch |err|
            fail(argv, 1, "cannot sync canonical text {s}: {s}\n", .{ temporary_name, @errorName(err) });
        file.close();
        file_open = false;
        parent.rename(temporary_name, basename) catch |err|
            fail(argv, 1, "cannot publish canonical text {s}: {s}\n", .{ path, @errorName(err) });
        std.posix.fsync(parent.fd) catch |err|
            fail(argv, 1, "cannot sync atomic-write parent {s}: {s}\n", .{ parent_path, @errorName(err) });
    }

    // --- process helpers -----------------------------------------------------

    /// Reports directory-entry existence without following the final symlink.
    /// In particular, a dangling manifest symlink is present and therefore
    /// invalid in base-only mode; only ENOENT means absent.
    fn pathEntryExists(path: []const u8) !bool {
        _ = std.posix.fstatat(
            std.posix.AT.FDCWD,
            path,
            std.posix.AT.SYMLINK_NOFOLLOW,
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn captureCommand(
        gpa: std.mem.Allocator,
        child_argv: []const []const u8,
        max_output_bytes: usize,
    ) ![]u8 {
        var environment = try std.process.getEnvMap(gpa);
        defer environment.deinit();
        try environment.put("LC_ALL", "C");
        try environment.put("LANG", "C");
        var child = std.process.Child.init(child_argv, gpa);
        child.env_map = &environment;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        // collectOutput asserts both stdout and stderr are .Pipe; capture stderr
        // into a discarded buffer rather than inheriting it.
        child.stderr_behavior = .Pipe;
        try child.spawn();

        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(gpa);
        var stderr_dummy: std.ArrayList(u8) = .empty;
        defer stderr_dummy.deinit(gpa);
        try child.collectOutput(gpa, &stdout, &stderr_dummy, max_output_bytes);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0)
                return error.ChildFailed,
            else => return error.ChildFailed,
        }
        return stdout.toOwnedSlice(gpa);
    }

    /// gitCapture runs a child process capturing stdout and failing on any
    /// non-zero termination. Most metadata commands are tightly bounded.
    fn gitCapture(gpa: std.mem.Allocator, child_argv: []const []const u8) ![]u8 {
        return captureCommand(gpa, child_argv, 16 * 1024 * 1024);
    }

    /// gitSucceeds runs a child process with inherited streams and returns true
    /// iff it exits 0. Used for the best-effort / `|| true` git invocations.
    fn gitSucceeds(gpa: std.mem.Allocator, child_argv: []const []const u8) bool {
        var child = std.process.Child.init(child_argv, gpa);
        child.stdin_behavior = .Ignore;
        // The script sends prune/remove chatter to /dev/null; mirror with Ignore.
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return false;
        const term = child.wait() catch return false;
        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    /// gitMustSucceed runs a child process with inherited streams and fails the
    /// whole tool when it does not exit 0 — used where the script has no `|| true`.
    fn gitMustSucceed(gpa: std.mem.Allocator, argv: [][:0]u8, child_argv: []const []const u8) !void {
        try spawnMustSucceed(gpa, argv, child_argv);
    }

    /// spawnMustSucceed spawns `child_argv` with inherited stdio and aborts the
    /// tool (exit 1) if it cannot be spawned or exits non-zero, propagating the
    /// child's failure exactly as `set -e` did for the script's commands.
    fn spawnMustSucceed(gpa: std.mem.Allocator, argv: [][:0]u8, child_argv: []const []const u8) !void {
        var child = std.process.Child.init(child_argv, gpa);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch |err|
            fail(argv, 1, "cannot spawn {s}: {s}\n", .{ child_argv[0], @errorName(err) });
        const term = child.wait() catch |err|
            fail(argv, 1, "wait failed for {s}: {s}\n", .{ child_argv[0], @errorName(err) });
        switch (term) {
            .Exited => |code| if (code != 0)
                fail(argv, code, "{s} exited with status {d}\n", .{ child_argv[0], code }),
            .Signal => |sig| fail(argv, 1, "{s} terminated by signal {d}\n", .{ child_argv[0], sig }),
            else => fail(argv, 1, "{s} terminated abnormally\n", .{child_argv[0]}),
        }
    }
};

// =============================================================================
// webkit-provision / webkit-authoring / webkit-export: the pinned clone and
// the patch series around it.
// =============================================================================

const webkit_ops = struct {
    const origin_url = "https://github.com/oven-sh/WebKit.git";
    const authoring_branch = "collo-patches";

    /// The directories a JSCOnly build and its readers open; everything else in WebKit stays
    /// out of the checkout. `Tools/Scripts` holds the header-map tool the build extracts and
    /// the style checkers, which resolve their paths only from inside a checkout.
    const cone = [_][]const u8{
        "Source/cmake",               "Source/JavaScriptCore",
        "Source/WTF",                 "Source/bmalloc",
        "Source/ThirdParty/capstone", "Source/ThirdParty/unifdef",
        "Source/ThirdParty/gtest",    "Tools/Scripts",
    };

    const Paths = struct {
        repo_root: []u8,
        repository: []u8,
        authoring: []u8,
        patches: []u8,

        fn resolve(gpa: std.mem.Allocator, argv: [][:0]u8) !Paths {
            const repo_root = try jsc_build.resolveRepoRoot(gpa, argv);
            errdefer gpa.free(repo_root);
            const repository = try std.fs.path.join(gpa, &.{ repo_root, webkit_repository_relative });
            errdefer gpa.free(repository);
            const authoring_worktree = try std.fs.path.join(gpa, &.{ repo_root, webkit_authoring_relative });
            errdefer gpa.free(authoring_worktree);
            const patches = try std.fs.path.join(gpa, &.{ repo_root, webkit_patches_relative });
            return .{
                .repo_root = repo_root,
                .repository = repository,
                .authoring = authoring_worktree,
                .patches = patches,
            };
        }

        fn deinit(self: *Paths, gpa: std.mem.Allocator) void {
            gpa.free(self.repo_root);
            gpa.free(self.repository);
            gpa.free(self.authoring);
            gpa.free(self.patches);
        }
    };

    fn expectedCommit(argv: [][:0]u8) []const u8 {
        if (argv.len != 2)
            jsc_build.fail(argv, 64, "usage: {s} <expected_commit>\n", .{argv[0]});
        return argv[1];
    }

    fn requireGit(gpa: std.mem.Allocator, argv: [][:0]u8) void {
        if (!jsc_build.commandExists(gpa, "git"))
            jsc_build.fail(argv, 1, "missing required command: git\n", .{});
    }

    fn setSparseCone(gpa: std.mem.Allocator, argv: [][:0]u8, checkout: []const u8) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "git", "-C", checkout, "sparse-checkout", "set", "--cone" });
        try args.appendSlice(gpa, &cone);
        try jsc_build.gitMustSucceed(gpa, argv, args.items);
    }

    /// A shallow, blob-less fetch of exactly the pinned commit, checked out through the cone:
    /// around a hundred megabytes of objects plus the readable JSC tree, with blobs outside
    /// the cone fetched by git on demand. An existing clone is accepted only at the pin; the
    /// tool never removes one, because it is input, not output.
    pub fn provision(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        const commit = expectedCommit(argv);
        var paths = try Paths.resolve(gpa, argv);
        defer paths.deinit(gpa);
        requireGit(gpa, argv);

        if (try jsc_build.pathEntryExists(paths.repository)) {
            const head = jsc_build.gitCapture(gpa, &.{ "git", "-C", paths.repository, "rev-parse", "HEAD" }) catch null;
            defer if (head) |value| gpa.free(value);
            const head_text = if (head) |value| std.mem.trim(u8, value, " \t\r\n") else "<not a git checkout>";
            if (std.mem.eql(u8, head_text, commit)) {
                try jsc_build.checkWebkitCheckout(gpa, argv, paths.repository, commit);
                try jsc_build.stdoutPrint(argv, "WebKit already provisioned at {s}: {s}\n", .{ commit, paths.repository });
                return;
            }
            jsc_build.fail(argv, 1, "{s} exists with HEAD {s}, not the pin {s}; remove it to provision again\n", .{
                paths.repository, head_text, commit,
            });
        }

        std.fs.cwd().makePath(paths.repository) catch |err|
            jsc_build.fail(argv, 1, "cannot create {s}: {s}\n", .{ paths.repository, @errorName(err) });
        try jsc_build.gitMustSucceed(gpa, argv, &.{ "git", "init", "--quiet", paths.repository });
        try jsc_build.gitMustSucceed(gpa, argv, &.{ "git", "-C", paths.repository, "remote", "add", "origin", origin_url });
        try jsc_build.gitMustSucceed(gpa, argv, &.{
            "git", "-C", paths.repository, "fetch", "--depth=1", "--filter=blob:none", "origin", commit,
        });
        try setSparseCone(gpa, argv, paths.repository);
        try jsc_build.gitMustSucceed(gpa, argv, &.{ "git", "-C", paths.repository, "checkout", "--quiet", "--detach", commit });
        try jsc_build.checkWebkitCheckout(gpa, argv, paths.repository, commit);
        try jsc_build.stdoutPrint(argv, "WebKit provisioned at {s}: {s}\n", .{ commit, paths.repository });
    }

    /// The authoring worktree is where patches are written: a branch off the pin with the
    /// series applied as one commit per patch. It never feeds a build, and the tool never
    /// recreates it, because an existing one may hold uncommitted work.
    pub fn authoring(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        const commit = expectedCommit(argv);
        var paths = try Paths.resolve(gpa, argv);
        defer paths.deinit(gpa);
        requireGit(gpa, argv);
        try jsc_build.checkWebkitCheckout(gpa, argv, paths.repository, commit);
        if (try jsc_build.pathEntryExists(paths.authoring))
            jsc_build.fail(argv, 1, "{s} exists and may hold patch work; remove it yourself to recreate it\n", .{paths.authoring});

        _ = jsc_build.gitSucceeds(gpa, &.{ "git", "-C", paths.repository, "worktree", "prune" });
        try jsc_build.gitMustSucceed(gpa, argv, &.{
            "git",           "-C", paths.repository, "worktree",      "add",
            "--no-checkout", "-B", authoring_branch, paths.authoring, commit,
        });
        try setSparseCone(gpa, argv, paths.authoring);
        try jsc_build.gitMustSucceed(gpa, argv, &.{ "git", "-C", paths.authoring, "checkout", "--quiet" });

        const series = try jsc_build.sortedPatchFiles(gpa, argv, paths.patches);
        defer {
            for (series) |path| gpa.free(path);
            gpa.free(series);
        }
        if (series.len > 0) {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(gpa);
            try args.appendSlice(gpa, &.{ "git", "-C", paths.authoring, "am", "--whitespace=error" });
            for (series) |path| try args.append(gpa, path);
            try jsc_build.gitMustSucceed(gpa, argv, args.items);
        }
        try jsc_build.stdoutPrint(argv, "WebKit authoring worktree on {s} with {d} patches: {s}\n", .{
            authoring_branch, series.len, paths.authoring,
        });
    }

    /// The series is regenerated from the branch, never edited by hand: every commit past the
    /// pin becomes one numbered patch named after its subject, with the commit body as the
    /// patch's rationale. A dirty worktree or a branch whose base moved off the pin is refused.
    pub fn exportSeries(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        const commit = expectedCommit(argv);
        var paths = try Paths.resolve(gpa, argv);
        defer paths.deinit(gpa);
        requireGit(gpa, argv);
        if (!try jsc_build.pathEntryExists(paths.authoring))
            jsc_build.fail(argv, 1, "no authoring worktree at {s}; run webkit-authoring first\n", .{paths.authoring});

        const branch = jsc_build.gitCapture(gpa, &.{ "git", "-C", paths.authoring, "rev-parse", "--abbrev-ref", "HEAD" }) catch
            jsc_build.fail(argv, 1, "{s} is not a git worktree\n", .{paths.authoring});
        defer gpa.free(branch);
        if (!std.mem.eql(u8, std.mem.trim(u8, branch, " \t\r\n"), authoring_branch))
            jsc_build.fail(argv, 1, "authoring worktree is on {s}, not {s}\n", .{ std.mem.trim(u8, branch, " \t\r\n"), authoring_branch });

        const status = jsc_build.gitCapture(gpa, &.{ "git", "-C", paths.authoring, "status", "--porcelain", "--untracked-files=no" }) catch
            jsc_build.fail(argv, 1, "cannot read the status of {s}\n", .{paths.authoring});
        defer gpa.free(status);
        if (std.mem.trim(u8, status, " \t\r\n").len != 0)
            jsc_build.fail(argv, 1, "authoring worktree has uncommitted changes; commit or discard them before exporting\n", .{});

        const base = jsc_build.gitCapture(gpa, &.{ "git", "-C", paths.authoring, "merge-base", commit, "HEAD" }) catch
            jsc_build.fail(argv, 1, "authoring branch does not contain the pin {s}\n", .{commit});
        defer gpa.free(base);
        if (!std.mem.eql(u8, std.mem.trim(u8, base, " \t\r\n"), commit))
            jsc_build.fail(argv, 1, "authoring branch does not start at the pin {s}; rebase it onto the pin before exporting\n", .{commit});

        // Remove the previous series first, so a commit dropped from the branch disappears
        // from the directory instead of lingering as a stale numbered file.
        const previous = try jsc_build.sortedPatchFiles(gpa, argv, paths.patches);
        defer {
            for (previous) |path| gpa.free(path);
            gpa.free(previous);
        }
        for (previous) |path| std.fs.cwd().deleteFile(path) catch |err|
            jsc_build.fail(argv, 1, "cannot remove {s}: {s}\n", .{ path, @errorName(err) });

        const range = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{commit});
        defer gpa.free(range);
        try jsc_build.gitMustSucceed(gpa, argv, &.{
            "git",            "-C",                 paths.authoring, "format-patch", "--zero-commit",
            "--no-signature", "--output-directory", paths.patches,   range,
        });
        const exported = try jsc_build.sortedPatchFiles(gpa, argv, paths.patches);
        defer {
            for (exported) |path| gpa.free(path);
            gpa.free(exported);
        }
        try jsc_build.stdoutPrint(argv, "exported {d} patches to {s}\n", .{ exported.len, paths.patches });
    }
};

// =============================================================================
// apply-patches: apply patches/<dep>/*.patch to a private copy of a dep.
// =============================================================================

const apply_patches = struct {
    /// Upper bound on a single copied file. ls-hpack ships a ~4.3 MiB generated
    /// header (`huff-tables.h`); 64 MiB leaves ample headroom while still bounding
    /// memory. A file above this is treated as a hard error rather than truncated.
    const file_bytes_max: usize = 64 * 1024 * 1024;

    /// Upper bound on the number of patch files we will gather. The patch set is a
    /// handful of files; a fixed cap keeps the loop bounded (TigerStyle).
    const patch_count_max: usize = 1024;

    /// Upper bound on a symlink target length we will reproduce. POSIX PATH_MAX is
    /// 4096; ls-hpack ships no symlinks, but `cp -R` copies them, so we mirror that.
    const symlink_target_bytes_max: usize = 4096;

    pub fn run(gpa: std.mem.Allocator, args: [][:0]u8) !void {
        if (args.len != 4) {
            fail("usage: {s} <source_dir> <patch_dir> <out_dir>", .{args[0]});
            std.process.exit(64);
        }
        const source_dir_path = args[1];
        const patch_dir_path = args[2];
        const out_dir_path = args[3];

        // The system `patch` binary is the only external dependency; verify it is
        // resolvable up front so the failure is a clear diagnostic, not a cryptic
        // spawn error mid-run. The bash also checked perl/find/sort/cp, but those
        // are now done in-process, so only `patch` remains to validate.
        if (!commandExists(gpa, "patch")) {
            fail("missing required command: patch", .{});
            std.process.exit(1);
        }

        // Validate inputs exactly like the bash: source must hold lshpack.c, and
        // the patch dir must exist as a directory.
        requireSourceMarker(source_dir_path);
        requirePatchDir(patch_dir_path);

        // rm -rf out_dir; mkdir -p out_dir.
        resetOutputDir(out_dir_path);

        // cp -R source_dir/. out_dir/ (recursive, dotfiles and symlinks included).
        copyTree(gpa, source_dir_path, out_dir_path) catch |err| {
            fail("failed to copy ls-hpack source {s} -> {s}: {s}", .{
                source_dir_path,
                out_dir_path,
                @errorName(err),
            });
            std.process.exit(1);
        };

        // Strip trailing CR from *.c, *.h, CMakeLists.txt across the copied tree.
        stripCarriageReturns(gpa, out_dir_path) catch |err| {
            fail("failed to normalize line endings in {s}: {s}", .{
                out_dir_path,
                @errorName(err),
            });
            std.process.exit(1);
        };

        // Enumerate patch_dir/*.patch (depth 1), byte-lexicographic sort.
        const patch_files = collectPatchFiles(gpa, patch_dir_path) catch |err| {
            fail("failed to enumerate patches in {s}: {s}", .{ patch_dir_path, @errorName(err) });
            std.process.exit(1);
        };
        defer freeStrings(gpa, patch_files);

        if (patch_files.len == 0) {
            fail("no ls-hpack patches found in {s}", .{patch_dir_path});
            std.process.exit(1);
        }

        // Apply each patch with the system `patch` binary, in sorted order. A failed
        // patch propagates `patch`'s own exit code and aborts the run, mirroring the
        // bash `set -e` semantics where the script exits with patch's status.
        for (patch_files) |patch_file_path| {
            applyPatch(gpa, out_dir_path, patch_file_path) catch |err| {
                fail("failed to apply patch {s}: {s}", .{ patch_file_path, @errorName(err) });
                std.process.exit(1);
            };
        }
    }

    /// Write a diagnostic line to stderr, prefix-free to match the bash `echo ... >&2`.
    fn fail(comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt ++ "\n", args);
    }

    /// Returns true if `name` resolves on PATH. Mirrors `command -v <name>`.
    /// Probes each PATH entry for a regular, executable file.
    fn commandExists(gpa: std.mem.Allocator, name: []const u8) bool {
        // An absolute or relative path with a slash is checked directly.
        if (std.mem.indexOfScalar(u8, name, '/') != null)
            return isExecutableFile(name);

        const path_env = std.process.getEnvVarOwned(gpa, "PATH") catch return false;
        defer gpa.free(path_env);

        var iter = std.mem.splitScalar(u8, path_env, ':');
        while (iter.next()) |dir| {
            if (dir.len == 0)
                continue;
            const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch return false;
            defer gpa.free(candidate);
            if (isExecutableFile(candidate))
                return true;
        }
        return false;
    }

    /// Returns true if `path` is a regular file with any execute bit set.
    fn isExecutableFile(path: []const u8) bool {
        const stat = std.fs.cwd().statFile(path) catch return false;
        if (stat.kind != .file)
            return false;
        const exec_bits: std.fs.File.Mode = 0o111;
        return (stat.mode & exec_bits) != 0;
    }

    /// Aborts (exit 1) unless `source_dir/lshpack.c` exists, matching the bash
    /// `[ -f "$source_dir/lshpack.c" ]` guard.
    fn requireSourceMarker(source_dir_path: []const u8) void {
        var dir = std.fs.cwd().openDir(source_dir_path, .{}) catch {
            fail("missing ls-hpack source: {s}/lshpack.c", .{source_dir_path});
            std.process.exit(1);
        };
        defer dir.close();
        const stat = dir.statFile("lshpack.c") catch {
            fail("missing ls-hpack source: {s}/lshpack.c", .{source_dir_path});
            std.process.exit(1);
        };
        if (stat.kind != .file) {
            fail("missing ls-hpack source: {s}/lshpack.c", .{source_dir_path});
            std.process.exit(1);
        }
    }

    /// Aborts (exit 1) unless `patch_dir` is an existing directory, matching the
    /// bash `[ -d "$patch_dir" ]` guard.
    fn requirePatchDir(patch_dir_path: []const u8) void {
        var dir = std.fs.cwd().openDir(patch_dir_path, .{}) catch {
            fail("missing ls-hpack patch dir: {s}", .{patch_dir_path});
            std.process.exit(1);
        };
        dir.close();
    }

    /// `rm -rf out_dir` followed by `mkdir -p out_dir`.
    fn resetOutputDir(out_dir_path: []const u8) void {
        std.fs.cwd().deleteTree(out_dir_path) catch |err| {
            fail("failed to remove output dir {s}: {s}", .{ out_dir_path, @errorName(err) });
            std.process.exit(1);
        };
        std.fs.cwd().makePath(out_dir_path) catch |err| {
            fail("failed to create output dir {s}: {s}", .{ out_dir_path, @errorName(err) });
            std.process.exit(1);
        };
    }

    /// Recursively copies every entry under `source_dir_path` into `out_dir_path`,
    /// preserving the relative tree (dotfiles and symlinks included). Equivalent to
    /// `cp -R source_dir/. out_dir/`: regular files are copied (mode preserved),
    /// directories are created, and symlinks are reproduced as symlinks. Entry kinds
    /// reported as `.unknown` by the directory iterator (some filesystems omit the
    /// dirent type) are classified with a `lstat`-equivalent so the tool does not
    /// spuriously fail — the kernel-resolved type, like `cp`/`find`, is authoritative.
    fn copyTree(gpa: std.mem.Allocator, source_dir_path: []const u8, out_dir_path: []const u8) !void {
        var source_dir = try std.fs.cwd().openDir(source_dir_path, .{ .iterate = true });
        defer source_dir.close();
        var out_dir = try std.fs.cwd().openDir(out_dir_path, .{});
        defer out_dir.close();

        var walker = try source_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            // Resolve `.unknown` (filesystems that do not return a dirent type) via
            // statFile so behavior matches `cp -R`/`find`, which always stat.
            const kind = try resolveEntryKind(source_dir, entry);

            switch (kind) {
                .directory => try out_dir.makePath(entry.path),
                .file => {
                    // Ensure the parent directory exists before copying the file;
                    // walk order is not guaranteed to visit a dir before its files.
                    if (std.fs.path.dirname(entry.path)) |parent|
                        try out_dir.makePath(parent);
                    try source_dir.copyFile(entry.path, out_dir, entry.path, .{});
                },
                .sym_link => {
                    // `cp -R` copies a symlink as a symlink (no dereference). Read
                    // its target and recreate it at the same relative path.
                    if (std.fs.path.dirname(entry.path)) |parent|
                        try out_dir.makePath(parent);
                    var target_buffer: [symlink_target_bytes_max]u8 = undefined;
                    const target = try source_dir.readLink(entry.path, &target_buffer);
                    try out_dir.symLink(target, entry.path, .{});
                },
                // Anything else (device, fifo, socket, ...) is not part of a source
                // checkout; fail loudly rather than silently skip.
                else => return error.UnexpectedDirEntryKind,
            }
        }
    }

    /// Resolves the kind of a walked directory entry. Most filesystems report the
    /// kind directly; those that do not (`.unknown`) are classified with `statFile`,
    /// matching how `cp -R`/`find` always stat. A symlink whose target is missing
    /// surfaces as `FileNotFound` from `statFile`; treat it as a symlink so it is
    /// reproduced verbatim rather than aborting the copy.
    fn resolveEntryKind(source_dir: std.fs.Dir, entry: std.fs.Dir.Walker.Entry) !std.fs.File.Kind {
        if (entry.kind != .unknown)
            return entry.kind;
        const stat = source_dir.statFile(entry.path) catch |err| switch (err) {
            error.FileNotFound => return .sym_link,
            else => return err,
        };
        return stat.kind;
    }

    /// Walks `out_dir_path` and rewrites every `*.c`, `*.h`, and `CMakeLists.txt`
    /// file, dropping a `\r` that immediately precedes a `\n` or sits at end of
    /// file (perl `s/\r$//`). Files without any such CR are left byte-identical and
    /// not rewritten, keeping the output deterministic for content addressing.
    fn stripCarriageReturns(gpa: std.mem.Allocator, out_dir_path: []const u8) !void {
        var out_dir = try std.fs.cwd().openDir(out_dir_path, .{ .iterate = true });
        defer out_dir.close();

        var walker = try out_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file)
                continue;
            if (!shouldStripCarriageReturns(entry.basename))
                continue;

            const original = try out_dir.readFileAlloc(gpa, entry.path, file_bytes_max);
            defer gpa.free(original);

            const stripped = try stripTrailingCrLines(gpa, original);
            defer gpa.free(stripped);

            // Only rewrite when content actually changed; avoids gratuitous churn.
            if (stripped.len != original.len)
                try out_dir.writeFile(.{ .sub_path = entry.path, .data = stripped });
        }
    }

    /// True for `*.c`, `*.h`, and `CMakeLists.txt`, matching the bash `find` filter.
    fn shouldStripCarriageReturns(basename: []const u8) bool {
        if (std.mem.eql(u8, basename, "CMakeLists.txt"))
            return true;
        if (std.mem.endsWith(u8, basename, ".c"))
            return true;
        if (std.mem.endsWith(u8, basename, ".h"))
            return true;
        return false;
    }

    /// Returns a freshly allocated copy of `input` with every `\r` that is followed
    /// by `\n`, or that is the final byte, removed. A `\r` anywhere else (mid-line)
    /// is preserved. This reproduces perl `-p` line processing with `s/\r$//`.
    fn stripTrailingCrLines(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = try .initCapacity(gpa, input.len);
        errdefer out.deinit(gpa);

        var index: usize = 0;
        while (index < input.len) : (index += 1) {
            const byte = input[index];
            if (byte == '\r') {
                const at_end = index + 1 == input.len;
                const before_newline = index + 1 < input.len and input[index + 1] == '\n';
                if (at_end or before_newline)
                    continue; // Drop this CR.
            }
            out.appendAssumeCapacity(byte);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Returns the absolute-or-relative paths of `patch_dir/*.patch` files at depth
    /// 1 (no recursion), sorted byte-lexicographically (LC_ALL=C). Caller owns the
    /// returned slice and each string; free with `freeStrings`.
    fn collectPatchFiles(gpa: std.mem.Allocator, patch_dir_path: []const u8) ![][]u8 {
        var patch_dir = try std.fs.cwd().openDir(patch_dir_path, .{ .iterate = true });
        defer patch_dir.close();

        var list: std.ArrayList([]u8) = .empty;
        errdefer freeStringsList(gpa, &list);

        var iter = patch_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file)
                continue;
            if (!std.mem.endsWith(u8, entry.name, ".patch"))
                continue;
            if (list.items.len >= patch_count_max)
                return error.TooManyPatches;

            // Build the full path so `patch -i` receives the same argument the bash
            // produced via `find <patch_dir> ... -print`.
            const full = try std.fs.path.join(gpa, &.{ patch_dir_path, entry.name });
            errdefer gpa.free(full);
            try list.append(gpa, full);
        }

        const paths = try list.toOwnedSlice(gpa);
        // Byte-lexicographic sort over the full path strings (LC_ALL=C order). All
        // paths share the patch_dir prefix, so this orders by filename in practice.
        std.mem.sort([]u8, paths, {}, lessThanBytes);
        return paths;
    }

    /// Byte-lexicographic ordering for two strings (LC_ALL=C sort semantics).
    fn lessThanBytes(_: void, lhs: []u8, rhs: []u8) bool {
        return std.mem.order(u8, lhs, rhs) == .lt;
    }

    /// Spawns `patch --no-backup-if-mismatch -l -d <out_dir> -p1 -i <patch_file>`,
    /// discarding stdout (bash redirected it to /dev/null) and letting stderr flow
    /// to the user. If `patch` exits nonzero, this process exits with that exact
    /// code (mirroring the bash `set -e`, which propagates patch's status: 1 for a
    /// rejected hunk, 2 for serious trouble). A spawn failure or abnormal
    /// termination is returned as an error — no failure is swallowed.
    fn applyPatch(
        gpa: std.mem.Allocator,
        out_dir_path: []const u8,
        patch_file_path: []const u8,
    ) !void {
        const argv = [_][]const u8{
            "patch",
            "--no-backup-if-mismatch",
            "-l",
            "-d",
            out_dir_path,
            "-p1",
            "-i",
            patch_file_path,
        };

        var child = std.process.Child.init(&argv, gpa);
        // Bash sent patch's stdout to /dev/null; keep stderr inherited for diagnostics.
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;

        const term = try child.spawnAndWait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    // Propagate patch's own exit code, matching the bash `set -e`
                    // behavior where the script exits with patch's status.
                    fail("failed to apply patch {s}: patch exited with code {d}", .{
                        patch_file_path,
                        code,
                    });
                    std.process.exit(code);
                }
            },
            .Signal, .Stopped, .Unknown => return error.PatchTerminatedAbnormally,
        }
    }

    /// Frees a slice of owned strings and the slice itself.
    fn freeStrings(gpa: std.mem.Allocator, strings: [][]u8) void {
        for (strings) |string|
            gpa.free(string);
        gpa.free(strings);
    }

    /// Frees every owned string still held by `list`, then the list backing memory.
    fn freeStringsList(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
        for (list.items) |string|
            gpa.free(string);
        list.deinit(gpa);
    }
};

// =============================================================================
// Archive architecture check: the GNU/BSD `ar` member walk plus ELF64 framing
// that proves every object in a static library targets the expected machine.
// Structural damage is an error; a well-formed archive built for another
// machine is a plain `false`.
// =============================================================================

const archive_magic = "!<arch>\n";
const archive_thin_magic = "!<thin>\n";
const archive_header_size: u64 = 60;
const archive_name_size: usize = 16;
const archive_size_offset: usize = 48;
const archive_size_size: usize = 10;
const archive_header_terminator = "`\n";
const archive_member_count_max: u32 = 1 << 20;
const archive_member_name_max: u64 = 4096;
const archive_string_table_size_max: u64 = 64 * 1024 * 1024;

const elf_header_size: u64 = 64;
const elf_class_64: u8 = 2;
const elf_data_little: u8 = 1;
const elf_version_current: u8 = 1;
const elf_type_relocatable: u16 = 1;

const ElfMachine = enum(u16) {
    x86_64 = 62,
    aarch64 = 183,
};

fn elfMachineForArch(arch: []const u8) ?ElfMachine {
    if (std.mem.eql(u8, arch, "x86_64")) return .x86_64;
    if (std.mem.eql(u8, arch, "aarch64")) return .aarch64;
    return null;
}

/// Reports whether every object member of `archive_path` targets `arch`. The
/// path must be a direct, unaliased regular file: prebuilt validation accepts
/// only what it can name exactly.
pub fn archiveMatchesArch(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    arch: []const u8,
) !bool {
    const machine = elfMachineForArch(arch) orelse return false;
    const file = try openDirectRegularFileNoLinks(archive_path);
    defer file.close();
    const stat_before = try file.stat();
    if (stat_before.kind != .file)
        return error.ArchiveNotRegular;
    const matches = try walkArchiveMachines(allocator, file, stat_before.size, machine);
    const stat_after = try file.stat();
    if (stat_after.kind != .file or stat_after.inode != stat_before.inode or
        stat_after.size != stat_before.size or stat_after.mode != stat_before.mode or
        stat_after.mtime != stat_before.mtime or stat_after.ctime != stat_before.ctime)
    {
        return error.ArchiveChanged;
    }
    return matches;
}

fn walkArchiveMachines(
    gpa: std.mem.Allocator,
    file: std.fs.File,
    archive_size: u64,
    machine: ElfMachine,
) !bool {
    var magic: [archive_magic.len]u8 = undefined;
    try readExactAt(file, &magic, 0);
    if (std.mem.eql(u8, &magic, archive_thin_magic))
        return error.ArchiveThin;
    if (!std.mem.eql(u8, &magic, archive_magic))
        return error.ArchiveBadMagic;

    var gnu_string_table: ?[]u8 = null;
    defer if (gnu_string_table) |table| gpa.free(table);
    var offset: u64 = archive_magic.len;
    var member_count: u32 = 0;
    var object_count: u32 = 0;
    var all_machines_match = true;
    while (offset < archive_size) {
        if (member_count == archive_member_count_max)
            return error.ArchiveTruncated;
        member_count += 1;
        const header_end = addBounded(offset, archive_header_size, archive_size) orelse
            return error.ArchiveTruncated;
        var header: [archive_header_size]u8 = undefined;
        try readExactAt(file, &header, offset);
        if (!std.mem.eql(
            u8,
            header[header.len - archive_header_terminator.len ..],
            archive_header_terminator,
        )) return error.ArchiveHeaderInvalid;
        const member_size = try parseCanonicalDecimal(
            header[archive_size_offset .. archive_size_offset + archive_size_size],
        );
        const data_offset = header_end;
        const data_end = addBounded(data_offset, member_size, archive_size) orelse
            return error.ArchiveTruncated;
        const raw_name = std.mem.trimRight(u8, header[0..archive_name_size], " ");

        if (std.mem.eql(u8, raw_name, "//")) {
            if (gnu_string_table != null)
                return error.ArchiveStringTableInvalid;
            if (member_size == 0 or member_size > archive_string_table_size_max)
                return error.ArchiveStringTableInvalid;
            const table = try gpa.alloc(u8, @intCast(member_size));
            errdefer gpa.free(table);
            try readExactAt(file, table, data_offset);
            try validateGnuStringTable(table);
            gnu_string_table = table;
        } else if (isArchiveSpecialName(raw_name)) {
            // Symbol tables are framing, not archive object members.
        } else {
            const member = try resolveArchiveMember(
                gpa,
                file,
                raw_name,
                data_offset,
                member_size,
                gnu_string_table,
            );
            defer if (member.owned_name) |name| gpa.free(name);
            // BSD symbol tables use the extended-name representation.
            if (!isArchiveSpecialName(member.name)) {
                const member_machine = try readElfObjectMachine(
                    file,
                    member.payload_offset,
                    member.payload_size,
                );
                if (member_machine != @intFromEnum(machine))
                    all_machines_match = false;
                object_count += 1;
            }
        }

        offset = data_end;
        if (member_size % 2 != 0) {
            const padding_end = addBounded(offset, 1, archive_size) orelse
                return error.ArchiveTruncated;
            var padding: [1]u8 = undefined;
            try readExactAt(file, &padding, offset);
            if (padding[0] != '\n')
                return error.ArchivePaddingInvalid;
            offset = padding_end;
        }
    }
    if (offset != archive_size)
        return error.ArchiveTruncated;
    if (object_count == 0)
        return error.ArchiveEmpty;
    return all_machines_match;
}

fn readElfObjectMachine(file: std.fs.File, offset: u64, size: u64) !u16 {
    if (size < elf_header_size)
        return error.ElfTooShort;
    var header: [elf_header_size]u8 = undefined;
    try readExactAt(file, &header, offset);
    if (!std.mem.eql(u8, header[0..4], "\x7fELF"))
        return error.ElfInvalid;
    if (header[4] != elf_class_64 or header[5] != elf_data_little)
        return error.ElfInvalid;
    if (header[6] != elf_version_current)
        return error.ElfInvalid;
    if (readU16(&header, 16) != elf_type_relocatable)
        return error.ElfInvalid;
    if (readU32(&header, 20) != elf_version_current)
        return error.ElfInvalid;
    if (readU16(&header, 52) != elf_header_size)
        return error.ElfInvalid;
    return readU16(&header, 18);
}

const ResolvedArchiveMember = struct {
    name: []const u8,
    owned_name: ?[]u8,
    payload_offset: u64,
    payload_size: u64,
};

fn resolveArchiveMember(
    gpa: std.mem.Allocator,
    file: std.fs.File,
    raw_name: []const u8,
    data_offset: u64,
    member_size: u64,
    gnu_string_table: ?[]const u8,
) !ResolvedArchiveMember {
    // BSD long names live in the member payload, prefixed by "#1/<len>".
    if (std.mem.startsWith(u8, raw_name, "#1/")) {
        const name_size = try parseCanonicalDecimal(raw_name[3..]);
        if (name_size == 0 or name_size > member_size or name_size > archive_member_name_max)
            return error.ArchiveMemberNameInvalid;
        const name = try gpa.alloc(u8, @intCast(name_size));
        errdefer gpa.free(name);
        try readExactAt(file, name, data_offset);
        try validateArchiveObjectName(name);
        return .{
            .name = name,
            .owned_name = name,
            .payload_offset = data_offset + name_size,
            .payload_size = member_size - name_size,
        };
    }
    // GNU long names are an offset into the "//" string table member.
    if (raw_name.len > 1 and raw_name[0] == '/' and std.ascii.isDigit(raw_name[1])) {
        const table = gnu_string_table orelse return error.ArchiveStringTableInvalid;
        const name_offset = try parseCanonicalDecimal(raw_name[1..]);
        if (name_offset >= table.len)
            return error.ArchiveStringTableInvalid;
        const name = try gnuStringTableName(table, @intCast(name_offset));
        try validateArchiveObjectName(name);
        return .{
            .name = name,
            .owned_name = null,
            .payload_offset = data_offset,
            .payload_size = member_size,
        };
    }

    var name = raw_name;
    if (std.mem.endsWith(u8, name, "/"))
        name = name[0 .. name.len - 1];
    try validateArchiveObjectName(name);
    return .{
        .name = name,
        .owned_name = null,
        .payload_offset = data_offset,
        .payload_size = member_size,
    };
}

fn isArchiveSpecialName(name: []const u8) bool {
    return std.mem.eql(u8, name, "/") or
        std.mem.eql(u8, name, "/SYM64/") or
        std.mem.eql(u8, name, "__.SYMDEF") or
        std.mem.eql(u8, name, "__.SYMDEF SORTED") or
        std.mem.eql(u8, name, "__.SYMDEF_64") or
        std.mem.eql(u8, name, "__.SYMDEF_64 SORTED");
}

fn validateArchiveObjectName(name: []const u8) !void {
    if (isArchiveSpecialName(name))
        return;
    if (name.len == 0 or name.len > archive_member_name_max)
        return error.ArchiveMemberNameInvalid;
    if (!std.unicode.utf8ValidateSlice(name))
        return error.ArchiveMemberNameInvalid;
    if (std.mem.indexOfAny(u8, name, "/\\\r\n\x00") != null)
        return error.ArchiveMemberNameInvalid;
    if (!std.mem.endsWith(u8, name, ".o"))
        return error.ArchiveMemberNameInvalid;
}

fn validateGnuStringTable(table: []const u8) !void {
    if (table.len < 2 or table[table.len - 1] != '\n')
        return error.ArchiveStringTableInvalid;
    if (std.mem.indexOfScalar(u8, table, 0) != null)
        return error.ArchiveStringTableInvalid;
    var offset: usize = 0;
    var entry_count: u32 = 0;
    while (offset < table.len) {
        // GNU ar may count one newline byte in the string-table payload to
        // make the table itself even-sized, after the final "/\n" entry.
        if (offset == table.len - 1 and table[offset] == '\n')
            break;
        if (entry_count == archive_member_count_max)
            return error.ArchiveStringTableInvalid;
        entry_count += 1;
        const end = std.mem.indexOfScalarPos(u8, table, offset, '\n') orelse
            return error.ArchiveStringTableInvalid;
        if (end <= offset or table[end - 1] != '/')
            return error.ArchiveStringTableInvalid;
        try validateArchiveObjectName(table[offset .. end - 1]);
        offset = end + 1;
    }
}

fn gnuStringTableName(table: []const u8, offset: usize) ![]const u8 {
    if (offset > 0 and table[offset - 1] != '\n')
        return error.ArchiveStringTableInvalid;
    const end = std.mem.indexOfScalarPos(u8, table, offset, '\n') orelse
        return error.ArchiveStringTableInvalid;
    if (end <= offset or table[end - 1] != '/')
        return error.ArchiveStringTableInvalid;
    return table[offset .. end - 1];
}

/// `ar` sizes are left-aligned decimals padded with spaces. Anything else — a
/// sign, a leading zero, trailing junk — is a forged header, not a big number.
fn parseCanonicalDecimal(raw: []const u8) !u64 {
    var digit_end: usize = 0;
    while (digit_end < raw.len and std.ascii.isDigit(raw[digit_end]))
        digit_end += 1;
    if (digit_end == 0)
        return error.ArchiveMemberSizeInvalid;
    if (digit_end > 1 and raw[0] == '0')
        return error.ArchiveMemberSizeInvalid;
    for (raw[digit_end..]) |byte| {
        if (byte != ' ')
            return error.ArchiveMemberSizeInvalid;
    }
    return std.fmt.parseInt(u64, raw[0..digit_end], 10) catch
        return error.ArchiveMemberSizeInvalid;
}

fn addBounded(start: u64, size: u64, limit: u64) ?u64 {
    const end = std.math.add(u64, start, size) catch return null;
    if (end > limit)
        return null;
    return end;
}

fn readExactAt(file: std.fs.File, buffer: []u8, offset: u64) !void {
    const size_read = file.preadAll(buffer, offset) catch return error.ArchiveReadFailed;
    if (size_read != buffer.len)
        return error.ArchiveTruncated;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

test "JSC build stamp v3 has one exact canonical field order" {
    const allocator = std.testing.allocator;
    const attestation_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const text = try jsc_build.buildStampText(allocator, .{
        .expected_commit = "0123456789abcdef0123456789abcdef01234567",
        .patch_hash = "patch-sha",
        .target_triple = "x86_64-linux-gnu",
        .target_arch = "x86_64",
        .cmake_build_type = "Release",
        .cxx_sysroot = "",
        .mcpu = "baseline",
        .compiler_version = "clang version 19.1.7",
        .tool_identity = "tool-sha",
    }, attestation_sha);
    defer allocator.free(text);

    try std.testing.expectEqualStrings(
        "schema=collo-jsc-stamp-v3\n" ++
            "commit=0123456789abcdef0123456789abcdef01234567\n" ++
            "patch_hash=patch-sha\n" ++
            "target_triple=x86_64-linux-gnu\n" ++
            "target_arch=x86_64\n" ++
            "cmake_build_type=Release\n" ++
            "cxx_sysroot=\n" ++
            "mcpu=baseline\n" ++
            "compiler=clang version 19.1.7\n" ++
            "script_sha=tool-sha\n" ++
            "attestation_sha256=" ++ attestation_sha,
        text,
    );
}

test "JSC command capture reports a nonzero child without corrupting allocator state" {
    try std.testing.expectError(
        error.ChildFailed,
        jsc_build.captureCommand(
            std.testing.allocator,
            &.{ "sh", "-c", "exit 7" },
            1024,
        ),
    );
}

test "JSC canonical records reject field delimiter injection" {
    const inputs = jsc_build.BuildAttestationInputs{
        .expected_commit = "commit\ninjected=value",
        .patch_hash = "patch-sha",
        .target_triple = "x86_64-linux-gnu",
        .target_arch = "x86_64",
        .cmake_build_type = "Release",
        .cxx_sysroot = "",
        .mcpu = "baseline",
        .compiler_version = "clang version 19.1.7",
        .tool_identity = "tool-sha",
    };
    try std.testing.expectError(
        error.InvalidCanonicalField,
        jsc_build.buildStampText(std.testing.allocator, inputs, "attestation-sha"),
    );
}

test "JSC canonical records reject CRLF, extra LF, and symlink aliases" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const record_path = try std.fs.path.join(allocator, &.{ root, "record" });
    defer allocator.free(record_path);
    const alias_path = try std.fs.path.join(allocator, &.{ root, "alias" });
    defer allocator.free(alias_path);
    const hardlink_path = try std.fs.path.join(allocator, &.{ root, "hardlink" });
    defer allocator.free(hardlink_path);
    const dangling_path = try std.fs.path.join(allocator, &.{ root, "dangling" });
    defer allocator.free(dangling_path);

    {
        const file = try tmp.dir.createFile("record", .{});
        defer file.close();
        try file.writeAll("schema=value\n");
    }
    try std.testing.expect(jsc_build.canonicalTextMatches(allocator, record_path, "schema=value"));

    {
        const file = try tmp.dir.createFile("record", .{ .truncate = true });
        defer file.close();
        try file.writeAll("schema=value\r\n");
    }
    try std.testing.expect(!jsc_build.canonicalTextMatches(allocator, record_path, "schema=value"));

    {
        const file = try tmp.dir.createFile("record", .{ .truncate = true });
        defer file.close();
        try file.writeAll("schema=value\n\n");
    }
    try std.testing.expect(!jsc_build.canonicalTextMatches(allocator, record_path, "schema=value"));

    try tmp.dir.symLink("record", "alias", .{});
    try std.testing.expect(!jsc_build.canonicalTextMatches(allocator, alias_path, "schema=value"));

    {
        const file = try tmp.dir.createFile("record", .{ .truncate = true });
        defer file.close();
        try file.writeAll("schema=value\n");
    }
    try std.posix.link(record_path, hardlink_path);
    try std.testing.expect(!jsc_build.canonicalTextMatches(allocator, hardlink_path, "schema=value"));
    try std.testing.expect(!jsc_build.canonicalTextMatches(allocator, record_path, "schema=value"));

    try tmp.dir.symLink("missing-target", "dangling", .{});
    try std.testing.expect(try jsc_build.pathEntryExists(dangling_path));
}

test "JSC semantic CMake and Ninja configuration is fail closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("source");
    try tmp.dir.makeDir("jsc");
    const source = try tmp.dir.realpathAlloc(allocator, "source");
    defer allocator.free(source);
    const build = try tmp.dir.realpathAlloc(allocator, "jsc");
    defer allocator.free(build);
    const archive_tail =
        "build JavaScriptCore: phony lib/libJavaScriptCore.a\n" ++
        "build lib/libWTF.a: CXX_STATIC_LIBRARY_LINKER__WTF_Release " ++
        "Source/WTF/wtf/CMakeFiles/WTF.dir/WTF.cpp.o\n" ++
        "build WTF: phony lib/libWTF.a\n" ++
        "build lib/libbmalloc.a: CXX_STATIC_LIBRARY_LINKER__bmalloc_Release " ++
        "Source/bmalloc/CMakeFiles/bmalloc.dir/bmalloc.cpp.o\n" ++
        "build bmalloc: phony lib/libbmalloc.a\n";
    const valid_ninja = "include CMakeFiles/rules.ninja\n" ++
        "build lib/libJavaScriptCore.a: CXX_STATIC_LIBRARY_LINKER__JavaScriptCore_Release " ++
        "Source/JavaScriptCore/CMakeFiles/JavaScriptCore.dir/runtime/Base.cpp.o " ++
        "Source/JavaScriptCore/CMakeFiles/LowLevelInterpreterLib.dir/llint/" ++
        "LowLevelInterpreter.cpp.o\n" ++ archive_tail;
    const c_compiler = try jsc_build.resolveCommandPath(allocator, "clang-19");
    defer allocator.free(c_compiler);
    const cxx_compiler = try jsc_build.resolveCommandPath(allocator, "clang++-19");
    defer allocator.free(cxx_compiler);
    const cache = try std.fmt.allocPrint(allocator, "CMAKE_BUILD_TYPE:STRING=Release\n" ++
        "CMAKE_HOME_DIRECTORY:INTERNAL={s}\n" ++
        "CMAKE_GENERATOR:INTERNAL=Ninja\n" ++
        "PORT:STRING=JSCOnly\n" ++
        "ENABLE_STATIC_JSC:BOOL=ON\n" ++
        "USE_THIN_ARCHIVES:BOOL=OFF\n" ++
        "USE_BUN_JSC_ADDITIONS:BOOL=ON\n" ++
        "EVENT_LOOP_TYPE:STRING=Generic\n" ++
        "USE_BUN_EVENT_LOOP:BOOL=OFF\n" ++
        "USE_EXTERNAL_MIMALLOC:BOOL=OFF\n" ++
        "USE_SYSTEM_MALLOC:BOOL=OFF\n" ++
        "ENABLE_REMOTE_INSPECTOR:BOOL=OFF\n" ++
        "ENABLE_API_TESTS:BOOL=ON\n" ++
        "ENABLE_JAVASCRIPT_SHELL:BOOL=OFF\n" ++
        "ENABLE_TOOLS:BOOL=OFF\n" ++
        "CMAKE_C_COMPILER:FILEPATH={s}\n" ++
        "CMAKE_CXX_COMPILER:FILEPATH={s}\n" ++
        "CMAKE_C_FLAGS:STRING=-mcpu=baseline\n" ++
        "CMAKE_CXX_FLAGS:STRING=-mcpu=baseline\n", .{ source, c_compiler, cxx_compiler });
    defer allocator.free(cache);
    {
        var build_dir = try tmp.dir.openDir("jsc", .{});
        defer build_dir.close();
        const file = try build_dir.createFile("CMakeCache.txt", .{});
        defer file.close();
        try file.writeAll(cache);
        const ninja = try build_dir.createFile("build.ninja", .{});
        defer ninja.close();
        try ninja.writeAll(valid_ninja);
    }
    const inputs = jsc_build.BuildAttestationInputs{
        .expected_commit = "commit",
        .patch_hash = "patch",
        .target_triple = "x86_64-linux-gnu",
        .target_arch = "x86_64",
        .cmake_build_type = "Release",
        .cxx_sysroot = "",
        .mcpu = "baseline",
        .compiler_version = "clang version",
        .tool_identity = "tool",
    };
    try jsc_build.validateCmakeConfiguration(allocator, build, source, inputs);
    try jsc_build.validateBuildNinja(allocator, build, "Release");

    const ninja_path = try std.fs.path.join(allocator, &.{ build, "build.ninja" });
    defer allocator.free(ninja_path);
    // Implicit inputs are dependencies, not members passed to the archive command.
    {
        const file = try std.fs.cwd().createFile(ninja_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("include CMakeFiles/rules.ninja\n" ++
            "build lib/libJavaScriptCore.a: " ++
            "CXX_STATIC_LIBRARY_LINKER__JavaScriptCore_Release external.o | " ++
            "Source/JavaScriptCore/CMakeFiles/JavaScriptCore.dir/runtime/Base.cpp.o " ++
            "Source/JavaScriptCore/CMakeFiles/LowLevelInterpreterLib.dir/llint/" ++
            "LowLevelInterpreter.cpp.o\n" ++ archive_tail);
    }
    try std.testing.expectError(
        error.BuildNinjaContractMismatch,
        jsc_build.validateBuildNinja(allocator, build, "Release"),
    );

    // A commented-out graph publishes no link edge at all.
    {
        const file = try std.fs.cwd().createFile(ninja_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("include CMakeFiles/rules.ninja\n" ++
            "# build lib/libJavaScriptCore.a: fake object.o\n" ++
            "# build lib/libWTF.a: fake object.o\n" ++
            "# build lib/libbmalloc.a: fake object.o\n");
    }
    try std.testing.expectError(
        error.BuildNinjaContractMismatch,
        jsc_build.validateBuildNinja(allocator, build, "Release"),
    );

    // Order-only inputs (after `||`) are ordering, not membership: an archive
    // whose objects only appear there has an empty object set.
    {
        const file = try std.fs.cwd().createFile(ninja_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("include CMakeFiles/rules.ninja\n" ++
            "build lib/libJavaScriptCore.a: " ++
            "CXX_STATIC_LIBRARY_LINKER__JavaScriptCore_Release external.o || " ++
            "Source/JavaScriptCore/CMakeFiles/JavaScriptCore.dir/runtime/Base.cpp.o\n" ++
            archive_tail);
    }
    try std.testing.expectError(
        error.BuildNinjaContractMismatch,
        jsc_build.validateBuildNinja(allocator, build, "Release"),
    );

    // The rules file must be included exactly once.
    {
        const file = try std.fs.cwd().createFile(ninja_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(valid_ninja ++ "include CMakeFiles/rules.ninja\n");
    }
    try std.testing.expectError(
        error.BuildNinjaContractMismatch,
        jsc_build.validateBuildNinja(allocator, build, "Release"),
    );

    const cache_path = try std.fs.path.join(allocator, &.{ build, "CMakeCache.txt" });
    defer allocator.free(cache_path);
    {
        const file = try std.fs.cwd().createFile(cache_path, .{ .truncate = true });
        defer file.close();
        const mutated = try std.mem.replaceOwned(
            u8,
            allocator,
            cache,
            "ENABLE_STATIC_JSC:BOOL=ON",
            "ENABLE_STATIC_JSC:BOOL=OFF",
        );
        defer allocator.free(mutated);
        try file.writeAll(mutated);
    }
    try std.testing.expectError(
        error.CmakeCacheValueMismatch,
        jsc_build.validateCmakeConfiguration(allocator, build, source, inputs),
    );
}

test "JSC atomic canonical publication is private and durable-shaped" {
    const allocator = std.testing.allocator;
    var random: [8]u8 = undefined;
    std.crypto.random.bytes(&random);
    const random_hex = std.fmt.bytesToHex(random, .lower);
    const root = try std.fmt.allocPrint(
        allocator,
        "/tmp/collo-buildtool-atomic-{s}",
        .{random_hex},
    );
    defer allocator.free(root);
    try std.fs.cwd().makeDir(root);
    defer std.fs.cwd().deleteTree(root) catch {};
    const record = try std.fs.path.join(allocator, &.{ root, "record" });
    defer allocator.free(record);
    const arg0 = try allocator.dupeZ(u8, "buildtool-test");
    defer allocator.free(arg0);
    var argv = [_][:0]u8{arg0};
    try jsc_build.writeTextAtomic(allocator, &argv, record, "schema=value");
    const file = try openDirectRegularFileNoLinks(record);
    defer file.close();
    const metadata = try std.posix.fstat(file.handle);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), metadata.mode & 0o777);
    const contents = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("schema=value\n", contents);
}
