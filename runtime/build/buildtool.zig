//! Single Collo build host tool. `main` dispatches on argv[1]:
//!   deps-provision        fetch each named pinned tree (pins.zig) at its pin into runtime/deps
//!   deps-verify           refuse a pinned tree the build reads in place unless it is pristine at its pin
//!   icu-build             build ICU with its data into runtime/deps/icu-build, or admit it by its stamp
//!   boringssl-build       build patched BoringSSL into runtime/deps/boringssl-build, or admit it by its stamp
//!   jsc-build             build the pinned, patched WebKit/JSC into runtime/deps/jsc-build
//!   jsc-validate-prebuilt admit an existing engine build by its provenance, never build
//!   webkit-authoring      create the patch-authoring worktree with the series applied
//!   webkit-export         regenerate runtime/patches/webkit from the authoring branch
//!   apply-patches         apply a <dep>/*.patch series to a private copy of a dep
//!
//! Every directory the tool creates or removes lies under the project's
//! `runtime/deps`, and a pristine tree there is input it never removes. Only
//! the Zig std library is used; external programs (git, cmake, ninja, make,
//! patch, ICU's configure) are spawned via std.process.Child with explicit
//! argv arrays, never a shell, and every spawn has its exit status checked.
//! Builds are serialized by rule, not by lock: two invocations on one build
//! directory clobber each other, so the build graph creates one step per
//! directory.
const std = @import("std");
/// Public so the build-tool suites reach the version-file parser through
/// this module; a second module rooted at pins.zig would put the file in two
/// modules of one test binary, which Zig refuses.
pub const pins = @import("pins.zig");

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

/// The longest series addendum name the tool accepts.
pub const series_addendum_name_bytes_max = 64;

/// A series addendum is a directory directly under `webkit_patches_relative` whose patches some
/// engines apply after the series. Its name is lowercase letters, digits and inner hyphens, so it
/// names exactly one directory there and can neither climb out of it nor alias the series itself.
pub fn validateSeriesAddendumName(name: []const u8) !void {
    if (name.len == 0 or name.len > series_addendum_name_bytes_max)
        return error.InvalidSeriesAddendum;
    if (name[0] == '-' or name[name.len - 1] == '-')
        return error.InvalidSeriesAddendum;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-' => {},
        else => return error.InvalidSeriesAddendum,
    };
}

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
    if (std.mem.eql(u8, sub, "deps-provision")) {
        pinned_trees.provision(gpa, sub_argv) catch |err| {
            printErr("collo deps-provision: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "deps-verify")) {
        pinned_trees.verify(gpa, sub_argv) catch |err| {
            printErr("collo deps-verify: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "icu-build")) {
        icu_build.run(gpa, sub_argv) catch |err| {
            printErr("collo icu-build: unexpected error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, sub, "boringssl-build")) {
        boringssl_build.run(gpa, sub_argv) catch |err| {
            printErr("collo boringssl-build: unexpected error: {s}\n", .{@errorName(err)});
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

const subcommand_list = "deps-provision|deps-verify|icu-build|boringssl-build|jsc-build|" ++
    "jsc-validate-prebuilt|webkit-authoring|webkit-export|apply-patches";

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
    const arg_icu_prefix = 10;
    /// The series addendum the engine applies after the series, or "" for none
    /// (`validateSeriesAddendumName`).
    const arg_series_addendum = 11;
    const arg_count_required = 12;

    const stamp_schema = "collo-jsc-stamp-v4";
    const attestation_schema = "collo-jsc-attestation-v3";
    const stamp_filename = ".collo-jsc.stamp";
    const attestation_filename = ".collo-jsc.attestation.v3";

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
        /// The install prefix of the pinned ICU build (`icu_build`) that
        /// CMake's FindICU is pointed at.
        icu_prefix: []const u8,
        /// The digest of that prefix's `include/` tree. The engine's archives
        /// hold no ICU code, only code compiled against these headers, so
        /// the headers are the whole of ICU the engine depends on.
        icu_headers_sha256: []const u8,
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
                "<mcpu> <tool_identity> <icu_prefix> <series_addendum>\n", .{argv[0]});
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
        // sorted, followed by the addendum's patches when the engine names
        // one. The pinned commit plus that list is the whole engine.
        const series = try engineSeries(gpa, argv, patch_dir, argv[arg_series_addendum]);
        defer {
            for (series) |path| gpa.free(path);
            gpa.free(series);
        }

        const patch_hash = try hashPatchSeries(gpa, argv, repo_root, series);
        defer gpa.free(patch_hash);
        const compiler_version = try clangVersionFirstLine(gpa, argv);
        defer gpa.free(compiler_version);

        // The ICU step runs before this one and fails unless its prefix holds
        // the build its stamp describes, so the headers read here are the ones
        // that stamp admitted.
        const icu_prefix = try absolutize(gpa, repo_root, argv[arg_icu_prefix]);
        defer gpa.free(icu_prefix);
        icu_build.validatePrefix(gpa, repo_root, icu_prefix) catch |err|
            fail(argv, 1, "invalid ICU prefix {s}: {s}\n", .{ icu_prefix, @errorName(err) });
        const icu_include = try std.fs.path.join(gpa, &.{ icu_prefix, "include" });
        defer gpa.free(icu_include);
        const icu_headers = native_build.digestTree(gpa, icu_include) catch |err|
            fail(argv, 1, "cannot digest the ICU headers in {s}: {s}\n", .{ icu_include, @errorName(err) });

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
            .icu_prefix = icu_prefix,
            .icu_headers_sha256 = &icu_headers.sha256,
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
            .icu_prefix = icu_prefix,
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

    /// The engine's source must be the pinned WebKit checkout, standalone and
    /// with HEAD at the pin. Its working tree may hold edits: the build reads
    /// a worktree of the commit, so uncommitted changes never reach it.
    fn checkWebkitCheckout(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        webkit_repo: []const u8,
        expected_commit: []const u8,
    ) !void {
        const webkit = pins.spec(.webkit);
        const problem = try pinned_trees.checkoutProblem(gpa, webkit_repo, expected_commit, webkit.marker, false);
        if (problem) |text| {
            defer gpa.free(text);
            fail(argv, 1, "runtime WebKit {s}: {s}\n", .{ webkit_repo, text });
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

    /// engineSeries returns the patches an engine applies, in apply order: the
    /// series in `patch_dir`, then, when `addendum` is not empty, the depth-1
    /// `*.patch` files of `patch_dir/<addendum>`, sorted the same way. An
    /// addendum that holds no patch is refused, because the engine would then
    /// build into a directory named for a configuration it does not have. The
    /// hash sees each patch by its path, so an engine with an addendum never
    /// shares a series hash with the series alone. The caller owns the slice
    /// and every path in it.
    fn engineSeries(gpa: std.mem.Allocator, argv: [][:0]u8, patch_dir: []const u8, addendum: []const u8) ![][]u8 {
        const series = try sortedPatchFiles(gpa, argv, patch_dir);
        if (addendum.len == 0)
            return series;
        defer gpa.free(series);
        errdefer for (series) |path| gpa.free(path);

        validateSeriesAddendumName(addendum) catch
            fail(argv, 1, "invalid series addendum name: {s}\n", .{addendum});
        const addendum_dir = try std.fs.path.join(gpa, &.{ patch_dir, addendum });
        defer gpa.free(addendum_dir);
        const extra = try sortedPatchFiles(gpa, argv, addendum_dir);
        defer gpa.free(extra);
        errdefer for (extra) |path| gpa.free(path);
        if (extra.len == 0)
            fail(argv, 1, "series addendum {s} holds no patch\n", .{addendum_dir});

        const all = try gpa.alloc([]u8, series.len + extra.len);
        @memcpy(all[0..series.len], series);
        @memcpy(all[series.len..], extra);
        return all;
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
        for (icu_build.cmake_cache_entries) |entry| {
            const expected = try std.mem.concat(gpa, u8, &.{ inputs.icu_prefix, entry.prefix_suffix });
            defer gpa.free(expected);
            try requireCmakeCacheValue(cache, entry.key, expected);
        }

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
            "icu_prefix={s}\n" ++
            "icu_headers_sha256={s}\n" ++
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
            inputs.icu_prefix,
            inputs.icu_headers_sha256,
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
            "icu_prefix={s}\nicu_headers_sha256={s}\n" ++
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
            inputs.icu_prefix,
            inputs.icu_headers_sha256,
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
            inputs.icu_prefix,
            inputs.icu_headers_sha256,
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
        icu_prefix: []const u8,
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

        // Every FindICU result is given, never searched for: a search can
        // settle on the machine's ICU, and the engine would then compile
        // against headers the binary does not link.
        var icu_args: [icu_build.cmake_cache_entries.len][]const u8 = undefined;
        var icu_args_count: usize = 0;
        defer for (icu_args[0..icu_args_count]) |arg| gpa.free(arg);
        for (icu_build.cmake_cache_entries) |entry| {
            icu_args[icu_args_count] = try std.fmt.allocPrint(gpa, "-D{s}={s}{s}", .{
                entry.key,
                spec.icu_prefix,
                entry.prefix_suffix,
            });
            icu_args_count += 1;
        }
        try args.appendSlice(gpa, icu_args[0..icu_args_count]);

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

        // WebKit's JSCOnly options copy ICU_ROOT and ICU_INCLUDE_DIRS from the
        // environment into the cache over the values given above.
        var environment = try native_build.environmentWithout(gpa, &engine_scrubbed_variables);
        defer environment.deinit();
        native_build.spawnMust(gpa, argv, args.items, .{ .env_map = &environment });
    }

    /// The caller's variables the engine's CMake must not see. The rest of
    /// the environment reaches it, because WebKit's generator scripts depend
    /// on the caller's locale; the profile and compiler checks of
    /// `validateCmakeConfigurationContents` catch the flags a variable could
    /// otherwise smuggle in.
    const engine_scrubbed_variables = [_][]const u8{ "ICU_ROOT", "ICU_INCLUDE_DIRS" };

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
// webkit-authoring / webkit-export: the patch series around the pinned clone,
// which deps-provision fetches.
// =============================================================================

const webkit_ops = struct {
    const authoring_branch = "collo-patches";

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
        try args.appendSlice(gpa, &pins.webkit_cone);
        try jsc_build.gitMustSucceed(gpa, argv, args.items);
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
            // A pinned tree is a git checkout; its metadata is not source, and
            // copying it would make the output depend on git's own bookkeeping.
            if (hasGitMetadataComponent(entry.path))
                continue;
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

    /// Whether a walked path is, or lies inside, a `.git` entry: the metadata
    /// directory of a checkout or the `.git` file of a submodule.
    fn hasGitMetadataComponent(path: []const u8) bool {
        var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, ".git"))
                return true;
        }
        return false;
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
// deps-provision / deps-verify: the pristine trees runtime/build/pins.zig
// lists, fetched once at their pins and never edited or removed.
// =============================================================================

const pinned_trees = struct {
    /// How much of `git status` a problem quotes; its first lines name the
    /// files that differ.
    const status_listing_bytes_max: usize = 2048;

    /// Fetches each named dependency (a `pins.Dependency` tag name) at its
    /// pin. A tree that already exists is accepted only when
    /// `checkoutProblem` finds nothing wrong with it, and never replaced:
    /// it is input, and a tool that removed it could remove someone's work.
    pub fn provision(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        if (argv.len < 2)
            jsc_build.fail(argv, 64, "usage: {s} <dependency>...\n", .{argv[0]});
        const repo_root = try jsc_build.resolveRepoRoot(gpa, argv);
        defer gpa.free(repo_root);
        if (!jsc_build.commandExists(gpa, "git"))
            jsc_build.fail(argv, 1, "missing required command: git\n", .{});
        for (argv[1..]) |name|
            try provisionOne(gpa, argv, repo_root, parseDependency(argv, name));
    }

    /// Fails unless each named tree is at its pin and, when the build reads
    /// the tree in place (`pins.Spec.read_in_place`), holds exactly the
    /// pinned commit's files. The build runs this before compiling any of
    /// them, so an edited or stale tree stops the build instead of reaching
    /// the binary.
    pub fn verify(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        if (argv.len < 2)
            jsc_build.fail(argv, 64, "usage: {s} <dependency>...\n", .{argv[0]});
        const repo_root = try jsc_build.resolveRepoRoot(gpa, argv);
        defer gpa.free(repo_root);
        for (argv[1..]) |name| {
            const dependency = parseDependency(argv, name);
            const spec = pins.spec(dependency);
            var loaded = loadPin(gpa, argv, repo_root, dependency);
            defer loaded.deinit(gpa);
            const tree = try treePath(gpa, repo_root, spec);
            defer gpa.free(tree);
            const problem = try checkoutProblem(gpa, tree, loaded.pin.commit, spec.marker, spec.read_in_place);
            if (problem) |text| {
                defer gpa.free(text);
                jsc_build.fail(argv, 1, "{s}: {s}\n`zig build deps-provision` fetches a missing tree at its pin; " ++
                    "it never replaces one that exists, so move this one aside first\n", .{ tree, text });
            }
        }
    }

    fn parseDependency(argv: [][:0]u8, name: []const u8) pins.Dependency {
        return std.meta.stringToEnum(pins.Dependency, name) orelse
            jsc_build.fail(argv, 64, "unknown dependency '{s}'\n", .{name});
    }

    /// The pin of `dependency`; a missing or malformed version file ends the
    /// tool.
    fn loadPin(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        repo_root: []const u8,
        dependency: pins.Dependency,
    ) pins.Loaded {
        var root = std.fs.cwd().openDir(repo_root, .{}) catch |err|
            jsc_build.fail(argv, 1, "cannot open the repository root {s}: {s}\n", .{ repo_root, @errorName(err) });
        defer root.close();
        return pins.load(gpa, root, dependency) catch |err|
            jsc_build.fail(argv, 1, "cannot read the pin {s}/{s}: {s}\n", .{
                pins.deps_relative,
                pins.spec(dependency).version_file,
                @errorName(err),
            });
    }

    fn treePath(gpa: std.mem.Allocator, repo_root: []const u8, spec: pins.Spec) ![]u8 {
        return std.fs.path.join(gpa, &.{ repo_root, pins.deps_relative, spec.tree });
    }

    fn provisionOne(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        repo_root: []const u8,
        dependency: pins.Dependency,
    ) !void {
        const spec = pins.spec(dependency);
        var loaded = loadPin(gpa, argv, repo_root, dependency);
        defer loaded.deinit(gpa);
        const pin = loaded.pin;
        const tree = try treePath(gpa, repo_root, spec);
        defer gpa.free(tree);

        if (try jsc_build.pathEntryExists(tree)) {
            const problem = try checkoutProblem(gpa, tree, pin.commit, spec.marker, spec.read_in_place);
            if (problem) |text| {
                defer gpa.free(text);
                jsc_build.fail(argv, 1, "{s}: {s}\nThe tool never replaces an existing tree; " ++
                    "move it aside and provision again\n", .{ tree, text });
            }
            try jsc_build.stdoutPrint(argv, "{s} already provisioned at {s}: {s}\n", .{ spec.tree, pin.commit, tree });
            return;
        }

        fetch(gpa, tree, spec, pin) catch |err| {
            // The tree did not exist before this call, so it holds nothing but
            // the failed fetch; leaving it would make every later run refuse
            // it as a tree off the pin.
            std.fs.cwd().deleteTree(tree) catch |delete_err|
                jsc_build.fail(argv, 1, "provisioning {s} failed ({s}), and removing the partial tree " ++
                    "{s} failed too ({s})\n", .{ spec.tree, @errorName(err), tree, @errorName(delete_err) });
            jsc_build.fail(argv, 1, "provisioning {s} at {s} failed: {s}\n", .{ spec.tree, pin.commit, @errorName(err) });
        };
        const problem = try checkoutProblem(gpa, tree, pin.commit, spec.marker, spec.read_in_place);
        if (problem) |text| {
            defer gpa.free(text);
            jsc_build.fail(argv, 1, "{s} was fetched, yet {s}\n", .{ tree, text });
        }
        try jsc_build.stdoutPrint(argv, "{s} provisioned at {s}: {s}\n", .{ spec.tree, pin.commit, tree });
    }

    /// A shallow fetch of exactly the pinned commit. A pin with a tag is
    /// fetched by its tag, which every server serves, while not every server
    /// serves an arbitrary commit; the commit the tag resolves to must then
    /// be the pin, so a moved tag fails instead of provisioning other code.
    fn fetch(gpa: std.mem.Allocator, tree: []const u8, spec: pins.Spec, pin: pins.Pin) !void {
        try std.fs.cwd().makePath(tree);
        try native_build.spawnChecked(gpa, &.{ "git", "init", "--quiet", tree }, .{});
        try native_build.spawnChecked(gpa, &.{ "git", "-C", tree, "remote", "add", "origin", pin.source }, .{});

        const ref = if (pin.tag) |tag|
            try std.fmt.allocPrint(gpa, "refs/tags/{s}", .{tag})
        else
            try gpa.dupe(u8, pin.commit);
        defer gpa.free(ref);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "git", "-C", tree, "fetch", "--depth=1" });
        if (spec.blobless)
            try args.append(gpa, "--filter=blob:none");
        try args.appendSlice(gpa, &.{ "origin", ref });
        try native_build.spawnChecked(gpa, args.items, .{});

        const fetched = try jsc_build.gitCapture(gpa, &.{ "git", "-C", tree, "rev-parse", "FETCH_HEAD^{commit}" });
        defer gpa.free(fetched);
        const fetched_commit = std.mem.trim(u8, fetched, " \t\r\n");
        if (!std.mem.eql(u8, fetched_commit, pin.commit)) {
            printErr("{s} resolves to {s}, not the pinned commit {s}\n", .{ ref, fetched_commit, pin.commit });
            return error.TagNotAtPin;
        }

        if (spec.sparse_cone.len != 0) {
            args.clearRetainingCapacity();
            try args.appendSlice(gpa, &.{ "git", "-C", tree, "sparse-checkout", "set", "--cone" });
            try args.appendSlice(gpa, spec.sparse_cone);
            try native_build.spawnChecked(gpa, args.items, .{});
        }
        try native_build.spawnChecked(gpa, &.{ "git", "-C", tree, "checkout", "--quiet", "--detach", pin.commit }, .{});
    }

    /// Null when `tree` is the pinned checkout; otherwise the first problem
    /// found, owned by `gpa`. The tree must hold `marker`, own its git
    /// metadata, be the top of its own checkout (a symlink or a directory
    /// inside another repository is refused) and have HEAD at `commit`. With
    /// `require_clean` its working tree must also match that commit exactly,
    /// with no untracked file, ignored or not.
    pub fn checkoutProblem(
        gpa: std.mem.Allocator,
        tree: []const u8,
        commit: []const u8,
        marker: []const u8,
        require_clean: bool,
    ) !?[]u8 {
        const marker_path = try std.fs.path.join(gpa, &.{ tree, marker });
        defer gpa.free(marker_path);
        std.fs.cwd().access(marker_path, .{}) catch
            return try std.fmt.allocPrint(gpa, "it holds no {s}, so it is not this dependency", .{marker});

        const git_directory = try std.fs.path.join(gpa, &.{ tree, ".git" });
        defer gpa.free(git_directory);
        var metadata = std.fs.cwd().openDir(git_directory, .{ .no_follow = true }) catch
            return try gpa.dupe(u8, "it does not own a .git directory, so its commit cannot be checked");
        metadata.close();
        if (!try gitOutputEquals(gpa, &.{ "git", "-C", tree, "rev-parse", "--path-format=absolute", "--git-common-dir" }, git_directory))
            return try gpa.dupe(u8, "it shares git metadata with another checkout");
        // The checkout root is compared literally, which refuses a symlink alias.
        if (!try gitOutputEquals(gpa, &.{ "git", "-C", tree, "rev-parse", "--show-toplevel" }, tree))
            return try gpa.dupe(u8, "it is not the top of a standalone git checkout");

        // HEAD must equal the pin, not merely contain it.
        const head = jsc_build.gitCapture(gpa, &.{ "git", "-C", tree, "rev-parse", "HEAD" }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return try gpa.dupe(u8, "git cannot read its HEAD"),
        };
        defer gpa.free(head);
        const head_commit = std.mem.trim(u8, head, " \t\r\n");
        if (!std.mem.eql(u8, head_commit, commit))
            return try std.fmt.allocPrint(gpa, "its HEAD is {s}, not the pinned commit {s}", .{ head_commit, commit });

        if (!require_clean)
            return null;
        // `--ignored` too: an include path or a copy of the tree reads a file
        // whatever ignore rule hides it from git.
        const status = jsc_build.gitCapture(gpa, &.{ "git", "-C", tree, "status", "--porcelain", "--untracked-files=all", "--ignored" }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return try gpa.dupe(u8, "git cannot read its status"),
        };
        defer gpa.free(status);
        const changes = std.mem.trim(u8, status, " \t\r\n");
        if (changes.len == 0)
            return null;
        return try std.fmt.allocPrint(gpa, "its files differ from the pinned commit:\n{s}", .{
            changes[0..@min(changes.len, status_listing_bytes_max)],
        });
    }

    fn gitOutputEquals(gpa: std.mem.Allocator, child_argv: []const []const u8, expected: []const u8) !bool {
        const output = jsc_build.gitCapture(gpa, child_argv) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        defer gpa.free(output);
        return std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), expected);
    }
};

// =============================================================================
// icu-build / boringssl-build: the native libraries built outside Zig's
// cache, each into one directory per target under runtime/deps and admitted
// afterwards by a stamp that names its inputs and digests its outputs.
// =============================================================================

pub const icu_generated_relative = "runtime/deps/icu-build";
pub const boringssl_generated_relative = "runtime/deps/boringssl-build";

/// The directory one native build owns under its generated root: the target
/// triple, plus `-<mcpu>` when the build pins a CPU model, so builds for two
/// CPU models never share a directory. The build script derives the same
/// name for the paths it hands to compilations and links.
pub fn nativeBuildKey(allocator: std.mem.Allocator, target_triple: []const u8, mcpu: []const u8) ![]u8 {
    if (mcpu.len == 0)
        return allocator.dupe(u8, target_triple);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ target_triple, mcpu });
}

const native_build = struct {
    /// A tree of installed headers holds a few hundred files; ten thousand
    /// means the digest is walking something it should not.
    const tree_file_count_max: usize = 10_000;

    /// Variables a configure script, make, CMake or WebKit's CMake reads as
    /// compiler, linker, install or dependency input. The tool sets each one
    /// a build needs explicitly, so none of the caller's shell leaks into a
    /// build its stamp does not describe.
    const caller_build_variables = [_][]const u8{
        // Compilers, tools and their flags.
        "CC",                        "CXX",                         "CPP",
        "CXXCPP",                    "CFLAGS",                      "CXXFLAGS",
        "CPPFLAGS",                  "LDFLAGS",                     "LIBS",
        "AR",                        "RANLIB",                      "NM",
        "LD",                        "STRIP",                       "OBJCOPY",
        "ASM",                       "ASMFLAGS",                    "PYTHON",
        "PYTHONPATH",
        // make: jobs and where `make install` writes.
                       "MAKEFLAGS",                   "MFLAGS",
        "MAKELEVEL",                 "GNUMAKEFLAGS",                "DESTDIR",
        // ICU's data build.
        "ICU_DATA_FILTER_FILE",      "ICU_DATA_BUILDTOOL_OPTS",
        // CMake, and the ICU location WebKit's JSCOnly options copy from the
        // environment into the cache over the pinned one.
            "CMAKE_TOOLCHAIN_FILE",
        "CMAKE_PREFIX_PATH",         "CMAKE_GENERATOR",             "CMAKE_BUILD_TYPE",
        "CMAKE_C_COMPILER_LAUNCHER", "CMAKE_CXX_COMPILER_LAUNCHER", "ICU_ROOT",
        "ICU_INCLUDE_DIRS",
    };

    pub const TreeDigest = struct {
        sha256: [jsc_build.Sha256.digest_length * 2]u8,
        file_count: usize,
    };

    /// A digest of every regular file under `root`, an absolute canonical
    /// directory: the SHA-256 of one `<file sha256>  <relative path>\n` line
    /// per file in byte-wise path order, so it depends on each file's path
    /// and bytes and on nothing else. A symlink or special file is an error,
    /// because a tree that points outside itself would let bytes the digest
    /// never read reach a compilation.
    pub fn digestTree(gpa: std.mem.Allocator, root: []const u8) !TreeDigest {
        var dir = try std.fs.cwd().openDir(root, .{ .iterate = true, .no_follow = true });
        defer dir.close();
        var paths: std.ArrayList([]u8) = .empty;
        defer {
            for (paths.items) |path| gpa.free(path);
            paths.deinit(gpa);
        }
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            const kind = if (entry.kind == .unknown) blk: {
                const metadata = try std.posix.fstatat(dir.fd, entry.path, std.posix.AT.SYMLINK_NOFOLLOW);
                if (std.posix.S.ISDIR(metadata.mode)) break :blk std.fs.File.Kind.directory;
                if (std.posix.S.ISREG(metadata.mode)) break :blk std.fs.File.Kind.file;
                return error.UnsupportedTreeEntry;
            } else entry.kind;
            switch (kind) {
                .directory => continue,
                .file => {},
                else => return error.UnsupportedTreeEntry,
            }
            if (paths.items.len == tree_file_count_max)
                return error.TreeTooLarge;
            const path = try gpa.dupe(u8, entry.path);
            errdefer gpa.free(path);
            try paths.append(gpa, path);
        }
        if (paths.items.len == 0)
            return error.EmptyTree;
        std.mem.sort([]u8, paths.items, {}, jsc_build.lessThanBytes);

        var outer = jsc_build.Sha256.init(.{});
        for (paths.items) |relative| {
            const full = try std.fs.path.join(gpa, &.{ root, relative });
            defer gpa.free(full);
            const file = try jsc_build.digestRegularFile(full);
            outer.update(&file.sha256);
            outer.update("  ");
            outer.update(relative);
            outer.update("\n");
        }
        var digest: [jsc_build.Sha256.digest_length]u8 = undefined;
        outer.final(&digest);
        return .{
            .sha256 = std.fmt.bytesToHex(digest, .lower),
            .file_count = paths.items.len,
        };
    }

    pub const Field = struct {
        key: []const u8,
        value: []const u8,
    };

    /// One `key=value` line per field, in order, with no final newline:
    /// `writeTextAtomic` adds it and `canonicalTextMatches` expects it. A
    /// value holding a line break or NUL is refused, since it could forge a
    /// field of its own.
    pub fn recordText(gpa: std.mem.Allocator, fields: []const Field) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(gpa);
        errdefer output.deinit();
        for (fields, 0..) |field, index| {
            try jsc_build.validateCanonicalField(field.key);
            try jsc_build.validateCanonicalField(field.value);
            if (std.mem.indexOfScalar(u8, field.key, '=') != null)
                return error.InvalidCanonicalField;
            if (index != 0)
                try output.writer.writeByte('\n');
            try output.writer.print("{s}={s}", .{ field.key, field.value });
        }
        return output.toOwnedSlice();
    }

    /// Output fields for each archive under `directory`, in the order given:
    /// `<stem>_sha256` and `<stem>_size`, the stem being the file name
    /// without `lib` and `.a`. Fails when an archive is missing or targets
    /// another machine than `target_arch`, which an up-to-date check reads as
    /// "rebuild".
    pub fn appendArchiveFields(
        gpa: std.mem.Allocator,
        fields: *std.ArrayList(Field),
        owned: *std.ArrayList([]u8),
        directory: []const u8,
        archives: []const []const u8,
        target_arch: []const u8,
    ) !void {
        for (archives) |relative| {
            const path = try std.fs.path.join(gpa, &.{ directory, relative });
            defer gpa.free(path);
            if (!try archiveMatchesArch(gpa, path, target_arch))
                return error.ArchiveTargetsAnotherMachine;
            const digest = try jsc_build.digestRegularFile(path);
            const name = std.fs.path.basename(relative);
            if (!std.mem.startsWith(u8, name, "lib") or !std.mem.endsWith(u8, name, ".a") or name.len <= "lib.a".len)
                return error.UnexpectedArchiveName;
            const stem = name["lib".len .. name.len - ".a".len];
            const sha_key = try ownedText(gpa, owned, try std.fmt.allocPrint(gpa, "{s}_sha256", .{stem}));
            const sha_value = try ownedText(gpa, owned, try gpa.dupe(u8, &digest.sha256));
            const size_key = try ownedText(gpa, owned, try std.fmt.allocPrint(gpa, "{s}_size", .{stem}));
            const size_value = try ownedText(gpa, owned, try std.fmt.allocPrint(gpa, "{d}", .{digest.size}));
            try fields.appendSlice(gpa, &.{
                .{ .key = sha_key, .value = sha_value },
                .{ .key = size_key, .value = size_value },
            });
        }
    }

    /// Records `text` in `owned`, which frees it with the record, and
    /// returns it.
    pub fn ownedText(gpa: std.mem.Allocator, owned: *std.ArrayList([]u8), text: []u8) ![]u8 {
        errdefer gpa.free(text);
        try owned.append(gpa, text);
        return text;
    }

    pub fn freeOwned(gpa: std.mem.Allocator, owned: *std.ArrayList([]u8)) void {
        for (owned.items) |text| gpa.free(text);
        owned.deinit(gpa);
    }

    /// `<repo_root>/<generated_relative>/<key>`, refused unless it lies
    /// strictly under the generated root with canonical ancestors: the tool
    /// deletes directories inside it, so no key may name anything else.
    pub fn keyDirectory(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        repo_root: []const u8,
        generated_relative: []const u8,
        key: []const u8,
    ) ![]u8 {
        const key_ok = key.len != 0 and
            std.mem.indexOfAny(u8, key, "/\x00\r\n") == null and
            !std.mem.eql(u8, key, ".") and
            !std.mem.eql(u8, key, "..");
        if (!key_ok)
            jsc_build.fail(argv, 1, "invalid native build directory name '{s}'\n", .{key});
        const generated_root = try std.fs.path.join(gpa, &.{ repo_root, generated_relative });
        defer gpa.free(generated_root);
        const directory = try std.fs.path.join(gpa, &.{ generated_root, key });
        errdefer gpa.free(directory);
        requireCanonicalDirectoryAncestors(directory) catch |err|
            jsc_build.fail(argv, 1, "invalid native build directory {s}: {s}\n", .{ directory, @errorName(err) });
        if (std.mem.eql(u8, directory, generated_root) or !pathIsWithin(directory, generated_root))
            jsc_build.fail(argv, 1, "native build directory {s} is outside {s}\n", .{ directory, generated_root });
        return directory;
    }

    /// The caller's environment without `caller_build_variables`, in the
    /// UTF-8 C locale (byte-wise collation, and UTF-8 for the scripts that
    /// read ICU's data sources), with Python told to write no bytecode next
    /// to the sources it runs.
    pub fn buildEnvironment(gpa: std.mem.Allocator) !std.process.EnvMap {
        var environment = try environmentWithout(gpa, &caller_build_variables);
        errdefer environment.deinit();
        try environment.put("LC_ALL", "C.UTF-8");
        try environment.put("LANG", "C.UTF-8");
        try environment.put("PYTHONDONTWRITEBYTECODE", "1");
        return environment;
    }

    /// The caller's environment without `names`.
    pub fn environmentWithout(gpa: std.mem.Allocator, names: []const []const u8) !std.process.EnvMap {
        var environment = try std.process.getEnvMap(gpa);
        errdefer environment.deinit();
        for (names) |name|
            environment.remove(name);
        return environment;
    }

    pub const SpawnOptions = struct {
        cwd: ?[]const u8 = null,
        env_map: ?*const std.process.EnvMap = null,
    };

    /// Runs `child_argv` with stdout and stderr inherited and fails with
    /// `error.ChildFailed` unless it exits 0.
    pub fn spawnChecked(gpa: std.mem.Allocator, child_argv: []const []const u8, options: SpawnOptions) !void {
        var child = std.process.Child.init(child_argv, gpa);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.cwd = options.cwd;
        child.env_map = options.env_map;
        const term = try child.spawnAndWait();
        switch (term) {
            .Exited => |code| if (code != 0) {
                printErr("{s} exited with status {d}\n", .{ child_argv[0], code });
                return error.ChildFailed;
            },
            .Signal => |signal| {
                printErr("{s} terminated by signal {d}\n", .{ child_argv[0], signal });
                return error.ChildFailed;
            },
            .Stopped, .Unknown => {
                printErr("{s} terminated abnormally\n", .{child_argv[0]});
                return error.ChildFailed;
            },
        }
    }

    /// `spawnChecked`, with a failure ending the tool. A native build leaves
    /// no stamp until it finishes, so the next run rebuilds from scratch.
    pub fn spawnMust(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        child_argv: []const []const u8,
        options: SpawnOptions,
    ) void {
        spawnChecked(gpa, child_argv, options) catch |err|
            jsc_build.fail(argv, 1, "{s} failed: {s}\n", .{ child_argv[0], @errorName(err) });
    }

    pub fn requireCommands(gpa: std.mem.Allocator, argv: [][:0]u8, commands: []const []const u8) void {
        for (commands) |command| {
            if (!jsc_build.commandExists(gpa, command))
                jsc_build.fail(argv, 1, "missing required command: {s}\n", .{command});
        }
    }

    /// The architecture this tool runs on, spelled as the build passes a
    /// target's (`toolchain.compilerRtArchName`).
    pub fn hostArch() []const u8 {
        return @tagName(@import("builtin").target.cpu.arch);
    }

    /// Removes the stamp first, so a build that stops halfway leaves a
    /// directory every later run treats as stale.
    pub fn removeStamp(argv: [][:0]u8, stamp_path: []const u8) void {
        std.fs.cwd().deleteFile(stamp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => jsc_build.fail(argv, 1, "cannot remove the stamp {s}: {s}\n", .{ stamp_path, @errorName(err) }),
        };
    }

    pub fn removeTree(argv: [][:0]u8, path: []const u8) void {
        std.fs.cwd().deleteTree(path) catch |err|
            jsc_build.fail(argv, 1, "cannot remove {s}: {s}\n", .{ path, @errorName(err) });
    }

    /// Replaces `worktree` with a fresh detached worktree of `commit` from
    /// `repository`. Only committed objects reach it, so an edit in the
    /// pristine tree never enters a build.
    pub fn recreateWorktree(
        gpa: std.mem.Allocator,
        argv: [][:0]u8,
        repository: []const u8,
        worktree: []const u8,
        commit: []const u8,
    ) !void {
        if (std.fs.path.dirname(worktree)) |parent|
            std.fs.cwd().makePath(parent) catch |err|
                jsc_build.fail(argv, 1, "cannot create {s}: {s}\n", .{ parent, @errorName(err) });
        // Pruning and removal are best effort: a registration whose directory
        // is gone, or a directory git no longer knows, is cleared below.
        _ = jsc_build.gitSucceeds(gpa, &.{ "git", "-C", repository, "worktree", "prune" });
        const removed = jsc_build.gitSucceeds(gpa, &.{
            "git", "-C", repository, "worktree", "remove", "--force", "--force", worktree,
        });
        if (!removed and try jsc_build.pathEntryExists(worktree))
            removeTree(argv, worktree);
        _ = jsc_build.gitSucceeds(gpa, &.{ "git", "-C", repository, "worktree", "prune" });
        try jsc_build.gitMustSucceed(gpa, argv, &.{
            "git", "-C", repository, "worktree", "add", "--force", "--force", "--detach", worktree, commit,
        });
    }
};

/// ICU4C with its data, built by ICU's own configure and make out of the
/// pinned tree into `<icu_generated_relative>/<key>/{build,install}`. A cross
/// build runs the host build's tools to generate the data, so it names that
/// build's key and digests its stamp as an input.
pub const icu_build = struct {
    // Positions are relative to sub_argv[0].
    const arg_mode = 1;
    const arg_target_triple = 2;
    const arg_target_arch = 3;
    const arg_cxx_sysroot = 4;
    const arg_mcpu = 5;
    const arg_host_key = 6;
    const arg_tool_identity = 7;
    const arg_count_required = 8;

    const stamp_schema = "collo-icu-stamp-v1";
    const stamp_filename = ".collo-icu.stamp";

    /// The archives under the install prefix, in the order a link names
    /// them: each one's undefined symbols resolve in the ones after it.
    pub const archives = [_][]const u8{
        "lib/libicui18n.a",
        "lib/libicuuc.a",
        "lib/libicudata.a",
    };

    const CmakeCacheEntry = struct {
        key: []const u8,
        /// Appended to the install prefix.
        prefix_suffix: []const u8,
    };

    /// What the engine's CMake receives for FindICU, each value the install
    /// prefix plus a suffix, and what `jsc_build` requires its cache to hold.
    pub const cmake_cache_entries = [_]CmakeCacheEntry{
        .{ .key = "ICU_ROOT", .prefix_suffix = "" },
        .{ .key = "ICU_INCLUDE_DIR", .prefix_suffix = "/include" },
        .{ .key = "ICU_I18N_LIBRARY_RELEASE", .prefix_suffix = "/lib/libicui18n.a" },
        .{ .key = "ICU_UC_LIBRARY_RELEASE", .prefix_suffix = "/lib/libicuuc.a" },
        .{ .key = "ICU_DATA_LIBRARY_RELEASE", .prefix_suffix = "/lib/libicudata.a" },
    };

    /// Static libraries with the data compiled into `libicudata.a`. Dynamic
    /// loading stays off, so ICU never calls dlopen. The libraries nothing in
    /// Collo calls (icuio, layoutex and the extras), the tests and the
    /// samples are not built; the tools are, because the data build runs
    /// them.
    const configure_options = [_][]const u8{
        "--enable-static",
        "--disable-shared",
        "--with-data-packaging=static",
        "--disable-dyload",
        "--disable-icu-config",
        "--disable-icuio",
        "--disable-layoutex",
        "--disable-extras",
        "--disable-tests",
        "--disable-samples",
    };

    /// Position-independent so the archives link into any executable.
    const base_flags = "-O2 -fPIC";

    /// ICU otherwise takes a data directory from the `ICU_DATA` variable and
    /// reads files there before the data linked into `libicudata.a`, so a
    /// process's environment could replace the data Collo was built with.
    const preprocessor_flags = "-DICU_NO_USER_DATA_OVERRIDE";

    const Mode = enum {
        /// Build when the stamp does not match.
        build,
        /// Fail when the stamp does not match (`-Djsc-prebuilt`).
        admit,
    };

    pub fn run(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        if (argv.len != arg_count_required)
            jsc_build.fail(argv, 64, "usage: {s} <build|admit> <target_triple> <target_arch> <cxx_sysroot> " ++
                "<mcpu> <host_key> <tool_identity>\n", .{argv[0]});
        const mode = std.meta.stringToEnum(Mode, argv[arg_mode]) orelse
            jsc_build.fail(argv, 64, "unknown mode '{s}'; expected build or admit\n", .{argv[arg_mode]});
        const target_triple = argv[arg_target_triple];
        const target_arch = argv[arg_target_arch];
        const cxx_sysroot = argv[arg_cxx_sysroot];
        const mcpu = argv[arg_mcpu];
        const host_key = argv[arg_host_key];
        const tool_identity = argv[arg_tool_identity];

        const cross = !std.mem.eql(u8, target_arch, native_build.hostArch());
        if (cross and host_key.len == 0)
            jsc_build.fail(argv, 1, "a {s} ICU on a {s} host needs the host build's tools; no host build was named\n", .{
                target_arch,
                native_build.hostArch(),
            });
        if (cross and cxx_sysroot.len == 0)
            jsc_build.fail(argv, 1, "cross-compiling ICU for {s} requires COLLO_CXX_SYSROOT=<sysroot>\n", .{target_arch});
        if (!cross and host_key.len != 0)
            jsc_build.fail(argv, 1, "a native ICU build takes no host build, got '{s}'\n", .{host_key});

        const repo_root = try jsc_build.resolveRepoRoot(gpa, argv);
        defer gpa.free(repo_root);
        const key = try nativeBuildKey(gpa, target_triple, mcpu);
        defer gpa.free(key);
        const root = try native_build.keyDirectory(gpa, argv, repo_root, icu_generated_relative, key);
        defer gpa.free(root);
        const build_dir = try std.fs.path.join(gpa, &.{ root, "build" });
        defer gpa.free(build_dir);
        const install_dir = try std.fs.path.join(gpa, &.{ root, "install" });
        defer gpa.free(install_dir);
        const stamp_path = try std.fs.path.join(gpa, &.{ root, stamp_filename });
        defer gpa.free(stamp_path);

        native_build.requireCommands(gpa, argv, &.{ "git", "make", "python3", "clang-19", "clang++-19" });
        const spec = pins.spec(.icu);
        var loaded = pinned_trees.loadPin(gpa, argv, repo_root, .icu);
        defer loaded.deinit(gpa);
        const commit = loaded.pin.commit;
        const tree = try pinned_trees.treePath(gpa, repo_root, spec);
        defer gpa.free(tree);
        try requirePristineTree(gpa, argv, tree, commit);
        const source_dir = try std.fs.path.join(gpa, &.{ tree, "icu4c/source" });
        defer gpa.free(source_dir);

        var host_build_dir: ?[]u8 = null;
        defer if (host_build_dir) |path| gpa.free(path);
        var host_stamp_sha256: []const u8 = "";
        var host_stamp_digest: jsc_build.FileDigest = undefined;
        if (cross) {
            const host_root = try native_build.keyDirectory(gpa, argv, repo_root, icu_generated_relative, host_key);
            defer gpa.free(host_root);
            host_build_dir = try std.fs.path.join(gpa, &.{ host_root, "build" });
            const host_stamp_path = try std.fs.path.join(gpa, &.{ host_root, stamp_filename });
            defer gpa.free(host_stamp_path);
            host_stamp_digest = jsc_build.digestRegularFile(host_stamp_path) catch |err|
                jsc_build.fail(argv, 1, "the cross build needs the host ICU build at {s}, whose stamp is unreadable: {s}\n", .{
                    host_root,
                    @errorName(err),
                });
            host_stamp_sha256 = &host_stamp_digest.sha256;
        }

        const compiler_version = try jsc_build.clangVersionFirstLine(gpa, argv);
        defer gpa.free(compiler_version);
        const flags = if (mcpu.len == 0)
            try gpa.dupe(u8, base_flags)
        else
            try std.fmt.allocPrint(gpa, "{s} -mcpu={s}", .{ base_flags, mcpu });
        defer gpa.free(flags);

        var configure_args: std.ArrayList([]const u8) = .empty;
        defer configure_args.deinit(gpa);
        var configure_owned: std.ArrayList([]u8) = .empty;
        defer native_build.freeOwned(gpa, &configure_owned);
        try configure_args.append(gpa, try native_build.ownedText(gpa, &configure_owned, try std.fs.path.join(gpa, &.{ source_dir, "configure" })));
        try configure_args.appendSlice(gpa, &configure_options);
        try configure_args.append(gpa, try native_build.ownedText(gpa, &configure_owned, try std.fmt.allocPrint(gpa, "--prefix={s}", .{install_dir})));
        if (host_build_dir) |host_build| {
            try configure_args.append(gpa, try native_build.ownedText(gpa, &configure_owned, try std.fmt.allocPrint(gpa, "--host={s}", .{target_triple})));
            try configure_args.append(gpa, try native_build.ownedText(gpa, &configure_owned, try std.fmt.allocPrint(gpa, "--with-cross-build={s}", .{host_build})));
        }
        const configure_line = try std.mem.join(gpa, " ", configure_args.items);
        defer gpa.free(configure_line);

        const c_compiler = if (cross)
            try std.fmt.allocPrint(gpa, "clang-19 --target={s} --sysroot={s}", .{ target_triple, cxx_sysroot })
        else
            try gpa.dupe(u8, "clang-19");
        defer gpa.free(c_compiler);
        const cxx_compiler = if (cross)
            try std.fmt.allocPrint(gpa, "clang++-19 --target={s} --sysroot={s}", .{ target_triple, cxx_sysroot })
        else
            try gpa.dupe(u8, "clang++-19");
        defer gpa.free(cxx_compiler);
        // The host GNU ld only carries the host's emulations; lld links any
        // target, as the engine's cross build also requires.
        const linker_flags = if (cross) "-fuse-ld=lld" else "";

        const inputs = [_]native_build.Field{
            .{ .key = "schema", .value = stamp_schema },
            .{ .key = "commit", .value = commit },
            .{ .key = "target_triple", .value = target_triple },
            .{ .key = "target_arch", .value = target_arch },
            .{ .key = "cxx_sysroot", .value = cxx_sysroot },
            .{ .key = "mcpu", .value = mcpu },
            .{ .key = "compiler", .value = compiler_version },
            .{ .key = "cc", .value = c_compiler },
            .{ .key = "cxx", .value = cxx_compiler },
            .{ .key = "flags", .value = flags },
            .{ .key = "cppflags", .value = preprocessor_flags },
            .{ .key = "ldflags", .value = linker_flags },
            .{ .key = "configure", .value = configure_line },
            .{ .key = "host_stamp_sha256", .value = host_stamp_sha256 },
            .{ .key = "script_sha", .value = tool_identity },
        };

        const outputs: Outputs = .{
            .build_dir = build_dir,
            .install_dir = install_dir,
            .target_arch = target_arch,
            .can_host_cross_builds = !cross,
        };
        if (try upToDate(gpa, &inputs, outputs, stamp_path)) {
            try jsc_build.stdoutPrint(argv, "ICU up to date: {s}\n", .{root});
            return;
        }
        if (mode == .admit)
            jsc_build.fail(argv, 1, "the ICU build {s} is stale or missing; build it without -Djsc-prebuilt " ++
                "(`zig build icu`)\n", .{root});

        native_build.removeStamp(argv, stamp_path);
        native_build.removeTree(argv, build_dir);
        native_build.removeTree(argv, install_dir);
        std.fs.cwd().makePath(build_dir) catch |err|
            jsc_build.fail(argv, 1, "cannot create {s}: {s}\n", .{ build_dir, @errorName(err) });

        var environment = try native_build.buildEnvironment(gpa);
        defer environment.deinit();
        try environment.put("CC", c_compiler);
        try environment.put("CXX", cxx_compiler);
        try environment.put("CFLAGS", flags);
        try environment.put("CXXFLAGS", flags);
        try environment.put("CPPFLAGS", preprocessor_flags);
        try environment.put("LDFLAGS", linker_flags);
        const in_build: native_build.SpawnOptions = .{ .cwd = build_dir, .env_map = &environment };

        native_build.spawnMust(gpa, argv, configure_args.items, in_build);
        const jobs_arg = try std.fmt.allocPrint(gpa, "-j{d}", .{jsc_build.buildJobCount(gpa)});
        defer gpa.free(jobs_arg);
        native_build.spawnMust(gpa, argv, &.{ "make", jobs_arg }, in_build);
        native_build.spawnMust(gpa, argv, &.{ "make", "install" }, in_build);

        // An out-of-tree build must leave its source untouched; a build that
        // wrote there would make the next run's tree check fail anyway, so
        // it fails here, naming the cause.
        try requirePristineTree(gpa, argv, tree, commit);

        const stamp_text = recordWithOutputs(gpa, &inputs, outputs) catch |err|
            jsc_build.fail(argv, 1, "the ICU build in {s} produced no valid output: {s}\n", .{ root, @errorName(err) });
        defer gpa.free(stamp_text);
        try jsc_build.writeTextAtomic(gpa, argv, stamp_path, stamp_text);
        try jsc_build.stdoutPrint(argv, "ICU built: {s}\n", .{root});
    }

    const Outputs = struct {
        build_dir: []const u8,
        install_dir: []const u8,
        target_arch: []const u8,
        /// A native build is also the host build a cross build runs
        /// configure against (`--with-cross-build`), which reads the build
        /// directory rather than the install prefix.
        can_host_cross_builds: bool,
    };

    /// What a cross build reads from its host build: the configuration
    /// fragment ICU's configure refuses to cross-compile without, written by
    /// the host's make next to the tools it ran.
    const cross_build_fragment = "config/icucross.mk";

    fn requirePristineTree(gpa: std.mem.Allocator, argv: [][:0]u8, tree: []const u8, commit: []const u8) !void {
        const spec = pins.spec(.icu);
        const problem = try pinned_trees.checkoutProblem(gpa, tree, commit, spec.marker, spec.read_in_place);
        if (problem) |text| {
            defer gpa.free(text);
            jsc_build.fail(argv, 1, "{s}: {s}\n", .{ tree, text });
        }
    }

    /// The stamp: the inputs, then what the build holds now: the installed
    /// headers' digest, each archive's digest and size, and for a build that
    /// can host a cross build the digest of `cross_build_fragment`, so a
    /// cleaned build directory makes the host stale instead of failing the
    /// cross build's configure.
    fn recordWithOutputs(
        gpa: std.mem.Allocator,
        inputs: []const native_build.Field,
        outputs: Outputs,
    ) ![]u8 {
        var fields: std.ArrayList(native_build.Field) = .empty;
        defer fields.deinit(gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer native_build.freeOwned(gpa, &owned);
        try fields.appendSlice(gpa, inputs);
        const include_dir = try std.fs.path.join(gpa, &.{ outputs.install_dir, "include" });
        defer gpa.free(include_dir);
        const headers = try native_build.digestTree(gpa, include_dir);
        try fields.append(gpa, .{
            .key = "headers_sha256",
            .value = try native_build.ownedText(gpa, &owned, try gpa.dupe(u8, &headers.sha256)),
        });
        try native_build.appendArchiveFields(gpa, &fields, &owned, outputs.install_dir, &archives, outputs.target_arch);
        if (outputs.can_host_cross_builds) {
            const fragment_path = try std.fs.path.join(gpa, &.{ outputs.build_dir, cross_build_fragment });
            defer gpa.free(fragment_path);
            const fragment = try jsc_build.digestRegularFile(fragment_path);
            try fields.append(gpa, .{
                .key = "cross_build_fragment_sha256",
                .value = try native_build.ownedText(gpa, &owned, try gpa.dupe(u8, &fragment.sha256)),
            });
        }
        return native_build.recordText(gpa, fields.items);
    }

    /// Whether the stamp is exactly the record the current inputs and the
    /// current build produce. Any output that is missing, changed or built
    /// for another machine reads as stale.
    fn upToDate(
        gpa: std.mem.Allocator,
        inputs: []const native_build.Field,
        outputs: Outputs,
        stamp_path: []const u8,
    ) !bool {
        const expected = recordWithOutputs(gpa, inputs, outputs) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        defer gpa.free(expected);
        return jsc_build.canonicalTextMatches(gpa, stamp_path, expected);
    }

    /// Refuses an ICU prefix the engine build was handed unless it is the
    /// `install` directory of a build under `icu_generated_relative`.
    pub fn validatePrefix(gpa: std.mem.Allocator, repo_root: []const u8, prefix: []const u8) !void {
        try requireCanonicalDirectoryAncestors(prefix);
        const generated_root = try std.fs.path.join(gpa, &.{ repo_root, icu_generated_relative });
        defer gpa.free(generated_root);
        if (!std.mem.eql(u8, std.fs.path.basename(prefix), "install"))
            return error.IcuPrefixIsNotAnInstallDirectory;
        const key_directory = std.fs.path.dirname(prefix) orelse return error.IcuPrefixOutsideGeneratedRoot;
        if (std.mem.eql(u8, key_directory, generated_root) or !pathIsWithin(key_directory, generated_root))
            return error.IcuPrefixOutsideGeneratedRoot;
        if (!std.mem.eql(u8, std.fs.path.dirname(key_directory) orelse "", generated_root))
            return error.IcuPrefixOutsideGeneratedRoot;
    }
};

/// BoringSSL with Collo's series applied to a worktree of the pinned commit
/// in `<boringssl_generated_relative>/<key>/src`, built with CMake into
/// `<key>/build`. Consumers compile against `src/include`, which holds the
/// series' header changes, and link `build/libssl.a` and `build/libcrypto.a`.
pub const boringssl_build = struct {
    // Positions are relative to sub_argv[0].
    const arg_target_triple = 1;
    const arg_target_arch = 2;
    const arg_cxx_sysroot = 3;
    const arg_mcpu = 4;
    const arg_tool_identity = 5;
    const arg_count_required = 6;

    const stamp_schema = "collo-boringssl-stamp-v1";
    const stamp_filename = ".collo-boringssl.stamp";

    /// Under the build directory, in the order a link names them.
    pub const archives = [_][]const u8{ "libssl.a", "libcrypto.a" };

    pub fn run(gpa: std.mem.Allocator, argv: [][:0]u8) !void {
        if (argv.len != arg_count_required)
            jsc_build.fail(argv, 64, "usage: {s} <target_triple> <target_arch> <cxx_sysroot> <mcpu> <tool_identity>\n", .{argv[0]});
        const target_triple = argv[arg_target_triple];
        const target_arch = argv[arg_target_arch];
        const cxx_sysroot = argv[arg_cxx_sysroot];
        const mcpu = argv[arg_mcpu];
        const tool_identity = argv[arg_tool_identity];
        const cross = !std.mem.eql(u8, target_arch, native_build.hostArch());
        if (cross and cxx_sysroot.len == 0)
            jsc_build.fail(argv, 1, "cross-compiling BoringSSL for {s} requires COLLO_CXX_SYSROOT=<sysroot>\n", .{target_arch});
        if (!cross and cxx_sysroot.len != 0)
            jsc_build.fail(argv, 1, "a native BoringSSL build takes no sysroot, got '{s}'\n", .{cxx_sysroot});

        const repo_root = try jsc_build.resolveRepoRoot(gpa, argv);
        defer gpa.free(repo_root);
        const key = try nativeBuildKey(gpa, target_triple, mcpu);
        defer gpa.free(key);
        const root = try native_build.keyDirectory(gpa, argv, repo_root, boringssl_generated_relative, key);
        defer gpa.free(root);
        const source_dir = try std.fs.path.join(gpa, &.{ root, "src" });
        defer gpa.free(source_dir);
        const build_dir = try std.fs.path.join(gpa, &.{ root, "build" });
        defer gpa.free(build_dir);
        const stamp_path = try std.fs.path.join(gpa, &.{ root, stamp_filename });
        defer gpa.free(stamp_path);

        native_build.requireCommands(gpa, argv, &.{ "git", "cmake", "ninja", "clang-19", "clang++-19" });
        const spec = pins.spec(.boringssl);
        var loaded = pinned_trees.loadPin(gpa, argv, repo_root, .boringssl);
        defer loaded.deinit(gpa);
        const commit = loaded.pin.commit;
        const tree = try pinned_trees.treePath(gpa, repo_root, spec);
        defer gpa.free(tree);
        const problem = try pinned_trees.checkoutProblem(gpa, tree, commit, spec.marker, spec.read_in_place);
        if (problem) |text| {
            defer gpa.free(text);
            jsc_build.fail(argv, 1, "{s}: {s}\n", .{ tree, text });
        }

        const patch_dir = if (loaded.pin.patches) |patches|
            try std.fs.path.join(gpa, &.{ repo_root, "runtime", patches })
        else
            try gpa.dupe(u8, "");
        defer gpa.free(patch_dir);
        const series = if (patch_dir.len == 0)
            try gpa.alloc([]u8, 0)
        else
            try jsc_build.sortedPatchFiles(gpa, argv, patch_dir);
        defer {
            for (series) |path| gpa.free(path);
            gpa.free(series);
        }
        const patch_hash = try jsc_build.hashPatchSeries(gpa, argv, repo_root, series);
        defer gpa.free(patch_hash);
        const compiler_version = try jsc_build.clangVersionFirstLine(gpa, argv);
        defer gpa.free(compiler_version);

        var cmake_args: std.ArrayList([]const u8) = .empty;
        defer cmake_args.deinit(gpa);
        var cmake_owned: std.ArrayList([]u8) = .empty;
        defer native_build.freeOwned(gpa, &cmake_owned);
        try cmake_args.appendSlice(gpa, &.{
            "cmake",                           "-S",                                   source_dir,
            "-B",                              build_dir,                              "-G",
            "Ninja",                           "-DCMAKE_BUILD_TYPE=Release",           "-DCMAKE_C_COMPILER=clang-19",
            "-DCMAKE_CXX_COMPILER=clang++-19", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DBUILD_SHARED_LIBS=OFF",
            // Testing needs Go and builds test binaries nothing links.
            "-DBUILD_TESTING=OFF",
        });
        if (mcpu.len != 0) {
            try cmake_args.append(gpa, try native_build.ownedText(gpa, &cmake_owned, try std.fmt.allocPrint(gpa, "-DCMAKE_C_FLAGS=-mcpu={s}", .{mcpu})));
            try cmake_args.append(gpa, try native_build.ownedText(gpa, &cmake_owned, try std.fmt.allocPrint(gpa, "-DCMAKE_CXX_FLAGS=-mcpu={s}", .{mcpu})));
        }
        if (cross) {
            try cmake_args.appendSlice(gpa, &.{
                "-DCMAKE_SYSTEM_NAME=Linux",
                try native_build.ownedText(gpa, &cmake_owned, try std.fmt.allocPrint(gpa, "-DCMAKE_SYSTEM_PROCESSOR={s}", .{target_arch})),
                try native_build.ownedText(gpa, &cmake_owned, try std.fmt.allocPrint(gpa, "-DCMAKE_SYSROOT={s}", .{cxx_sysroot})),
                try native_build.ownedText(gpa, &cmake_owned, try std.fmt.allocPrint(gpa, "-DCMAKE_C_COMPILER_TARGET={s}", .{target_triple})),
                try native_build.ownedText(gpa, &cmake_owned, try std.fmt.allocPrint(gpa, "-DCMAKE_CXX_COMPILER_TARGET={s}", .{target_triple})),
                // BoringSSL's hand-written assembly is compiled as CMake's ASM
                // language, which takes its own target; without it the `.S`
                // files assemble for the host and the archive mixes machines.
                try native_build.ownedText(gpa, &cmake_owned, try std.fmt.allocPrint(gpa, "-DCMAKE_ASM_COMPILER_TARGET={s}", .{target_triple})),
                // The host GNU ld only carries the host's emulations; lld
                // links any target, CMake's try_compile probes included.
                "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld",
                "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld",
                "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld",
            });
        }
        const cmake_line = try std.mem.join(gpa, " ", cmake_args.items);
        defer gpa.free(cmake_line);

        const inputs = [_]native_build.Field{
            .{ .key = "schema", .value = stamp_schema },
            .{ .key = "commit", .value = commit },
            .{ .key = "patch_hash", .value = patch_hash },
            .{ .key = "target_triple", .value = target_triple },
            .{ .key = "target_arch", .value = target_arch },
            .{ .key = "cxx_sysroot", .value = cxx_sysroot },
            .{ .key = "mcpu", .value = mcpu },
            .{ .key = "compiler", .value = compiler_version },
            .{ .key = "cmake", .value = cmake_line },
            .{ .key = "script_sha", .value = tool_identity },
        };

        if (try upToDate(gpa, &inputs, source_dir, build_dir, stamp_path, target_arch)) {
            try jsc_build.stdoutPrint(argv, "BoringSSL up to date: {s}\n", .{root});
            return;
        }

        native_build.removeStamp(argv, stamp_path);
        try native_build.recreateWorktree(gpa, argv, tree, source_dir, commit);
        native_build.removeTree(argv, build_dir);
        try jsc_build.applyPatchSeries(gpa, argv, source_dir, series);

        var environment = try native_build.buildEnvironment(gpa);
        defer environment.deinit();
        const with_environment: native_build.SpawnOptions = .{ .env_map = &environment };
        native_build.spawnMust(gpa, argv, cmake_args.items, with_environment);
        const jobs_arg = try std.fmt.allocPrint(gpa, "{d}", .{jsc_build.buildJobCount(gpa)});
        defer gpa.free(jobs_arg);
        native_build.spawnMust(gpa, argv, &.{
            "cmake", "--build", build_dir, "--target", "ssl", "crypto", "--parallel", jobs_arg,
        }, with_environment);

        const stamp_text = recordWithOutputs(gpa, &inputs, source_dir, build_dir, target_arch) catch |err|
            jsc_build.fail(argv, 1, "the BoringSSL build in {s} produced no valid output: {s}\n", .{ root, @errorName(err) });
        defer gpa.free(stamp_text);
        try jsc_build.writeTextAtomic(gpa, argv, stamp_path, stamp_text);
        try jsc_build.stdoutPrint(argv, "BoringSSL built: {s}\n", .{root});
    }

    /// The stamp: the inputs, then the patched headers' digest and each
    /// archive's digest and size.
    fn recordWithOutputs(
        gpa: std.mem.Allocator,
        inputs: []const native_build.Field,
        source_dir: []const u8,
        build_dir: []const u8,
        target_arch: []const u8,
    ) ![]u8 {
        var fields: std.ArrayList(native_build.Field) = .empty;
        defer fields.deinit(gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer native_build.freeOwned(gpa, &owned);
        try fields.appendSlice(gpa, inputs);
        const include_dir = try std.fs.path.join(gpa, &.{ source_dir, "include" });
        defer gpa.free(include_dir);
        const headers = try native_build.digestTree(gpa, include_dir);
        try fields.append(gpa, .{
            .key = "headers_sha256",
            .value = try native_build.ownedText(gpa, &owned, try gpa.dupe(u8, &headers.sha256)),
        });
        try native_build.appendArchiveFields(gpa, &fields, &owned, build_dir, &archives, target_arch);
        return native_build.recordText(gpa, fields.items);
    }

    fn upToDate(
        gpa: std.mem.Allocator,
        inputs: []const native_build.Field,
        source_dir: []const u8,
        build_dir: []const u8,
        stamp_path: []const u8,
        target_arch: []const u8,
    ) !bool {
        const expected = recordWithOutputs(gpa, inputs, source_dir, build_dir, target_arch) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        defer gpa.free(expected);
        return jsc_build.canonicalTextMatches(gpa, stamp_path, expected);
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
    // ICU's build names the objects of its static libraries `.ao`, to keep
    // them apart from the objects of its shared ones; every member is still
    // an ELF object whose machine the walk checks.
    if (!std.mem.endsWith(u8, name, ".o") and !std.mem.endsWith(u8, name, ".ao"))
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

test "JSC build stamp v4 has one exact canonical field order" {
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
        .icu_prefix = "/repo/runtime/deps/icu-build/x86_64-linux-gnu/install",
        .icu_headers_sha256 = "icu-headers-sha",
    }, attestation_sha);
    defer allocator.free(text);

    try std.testing.expectEqualStrings(
        "schema=collo-jsc-stamp-v4\n" ++
            "commit=0123456789abcdef0123456789abcdef01234567\n" ++
            "patch_hash=patch-sha\n" ++
            "target_triple=x86_64-linux-gnu\n" ++
            "target_arch=x86_64\n" ++
            "cmake_build_type=Release\n" ++
            "cxx_sysroot=\n" ++
            "mcpu=baseline\n" ++
            "compiler=clang version 19.1.7\n" ++
            "script_sha=tool-sha\n" ++
            "icu_prefix=/repo/runtime/deps/icu-build/x86_64-linux-gnu/install\n" ++
            "icu_headers_sha256=icu-headers-sha\n" ++
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
        .icu_prefix = "/repo/runtime/deps/icu-build/x86_64-linux-gnu/install",
        .icu_headers_sha256 = "icu-headers-sha",
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
        "CMAKE_CXX_FLAGS:STRING=-mcpu=baseline\n" ++
        "ICU_ROOT:UNINITIALIZED=/icu/install\n" ++
        "ICU_INCLUDE_DIR:PATH=/icu/install/include\n" ++
        "ICU_I18N_LIBRARY_RELEASE:FILEPATH=/icu/install/lib/libicui18n.a\n" ++
        "ICU_UC_LIBRARY_RELEASE:FILEPATH=/icu/install/lib/libicuuc.a\n" ++
        "ICU_DATA_LIBRARY_RELEASE:FILEPATH=/icu/install/lib/libicudata.a\n", .{ source, c_compiler, cxx_compiler });
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
        .icu_prefix = "/icu/install",
        .icu_headers_sha256 = "icu-headers",
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
