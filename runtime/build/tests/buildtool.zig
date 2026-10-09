const std = @import("std");
const buildtool = @import("collo_buildtool");

const archive_magic = "!<arch>\n";
const x86_64_machine: u16 = 62;
const aarch64_machine: u16 = 183;

const standalone_cmake_cache =
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
    "ENABLE_TOOLS:BOOL=OFF\n";

const jsc_main_object = "Source/JavaScriptCore/CMakeFiles/JavaScriptCore.dir/runtime/VM.cpp.o";
const jsc_llint_object =
    "Source/JavaScriptCore/CMakeFiles/LowLevelInterpreterLib.dir/llint/LowLevelInterpreter.cpp.o";
const wtf_object = "Source/WTF/wtf/CMakeFiles/WTF.dir/WTF.cpp.o";
const bmalloc_object = "Source/bmalloc/CMakeFiles/bmalloc.dir/bmalloc.cpp.o";
const jsc_ninja_prefix = "include CMakeFiles/rules.ninja\n" ++
    "build lib/libJavaScriptCore.a: CXX_STATIC_LIBRARY_LINKER__JavaScriptCore_Release ";
const jsc_ninja_tail = "build JavaScriptCore: phony lib/libJavaScriptCore.a\n" ++
    "build lib/libWTF.a: CXX_STATIC_LIBRARY_LINKER__WTF_Release " ++ wtf_object ++ "\n" ++
    "build WTF: phony lib/libWTF.a\n" ++
    "build lib/libbmalloc.a: CXX_STATIC_LIBRARY_LINKER__bmalloc_Release " ++ bmalloc_object ++ "\n" ++
    "build bmalloc: phony lib/libbmalloc.a\n";
const standalone_build_ninja = jsc_ninja_prefix ++ jsc_main_object ++ " " ++
    jsc_llint_object ++ "\n" ++ jsc_ninja_tail;

// Independent fixtures pin the embedding profile rather than inheriting producer defaults.
test "buildtool JSC standalone profile arguments and cache agree" {
    const expected = [_][]const u8{
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
    try std.testing.expectEqual(expected.len, buildtool.jsc_cmake_profile_args.len);
    for (expected, buildtool.jsc_cmake_profile_args) |argument, actual| {
        try std.testing.expectEqualStrings(argument, actual);
    }
    try buildtool.validateJscCmakeProfile(standalone_cmake_cache);
}

// Every required setting must survive missing, mismatched, and duplicate cache entries.
test "buildtool JSC standalone profile rejects each missing mismatched or duplicate value" {
    const allocator = std.testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, standalone_cmake_cache, '\n');
    while (lines.next()) |line| {
        const missing = try std.mem.replaceOwned(u8, allocator, standalone_cmake_cache, line, "");
        defer allocator.free(missing);
        try std.testing.expectError(
            error.MissingCmakeCacheKey,
            buildtool.validateJscCmakeProfile(missing),
        );

        const equals = std.mem.indexOfScalar(u8, line, '=').?;
        const wrong_line = try std.fmt.allocPrint(allocator, "{s}=unexpected", .{line[0..equals]});
        defer allocator.free(wrong_line);
        const mismatch = try std.mem.replaceOwned(
            u8,
            allocator,
            standalone_cmake_cache,
            line,
            wrong_line,
        );
        defer allocator.free(mismatch);
        try std.testing.expectError(
            error.CmakeCacheValueMismatch,
            buildtool.validateJscCmakeProfile(mismatch),
        );

        const duplicate = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{
            standalone_cmake_cache, line,
        });
        defer allocator.free(duplicate);
        try std.testing.expectError(
            error.DuplicateCmakeCacheKey,
            buildtool.validateJscCmakeProfile(duplicate),
        );
    }
}

// Malformed cache bytes cannot disguise a missing or overridden profile value.
test "buildtool JSC standalone profile rejects malformed cache bytes" {
    try std.testing.expectError(
        error.MalformedCmakeCache,
        buildtool.validateJscCmakeProfile(standalone_cmake_cache ++ "\r\n"),
    );
    try std.testing.expectError(
        error.MalformedCmakeCache,
        buildtool.validateJscCmakeProfile(standalone_cmake_cache ++ "\x00"),
    );
}

// Synthetic edges isolate the native main-plus-LLInt archive contract from compiler execution.
test "buildtool JSC native archive graph requires every object group" {
    const allocator = std.testing.allocator;
    try buildtool.validateJscBuildNinja(standalone_build_ninja, "Release");
    for ([_][]const u8{ jsc_main_object, jsc_llint_object, wtf_object, bmalloc_object }) |object| {
        const missing = try std.mem.replaceOwned(u8, allocator, standalone_build_ninja, object, "");
        defer allocator.free(missing);
        try std.testing.expectError(
            error.BuildNinjaContractMismatch,
            buildtool.validateJscBuildNinja(missing, "Release"),
        );
    }
    const split_jit = try std.mem.replaceOwned(
        u8,
        allocator,
        standalone_build_ninja,
        "JavaScriptCore.dir/",
        "JavaScriptCoreJIT.dir/",
    );
    defer allocator.free(split_jit);
    try std.testing.expectError(
        error.BuildNinjaContractMismatch,
        buildtool.validateJscBuildNinja(split_jit, "Release"),
    );
}

// Dependencies outside Ninja's explicit input list never supply archive members.
test "buildtool JSC native archive graph rejects dependency-only main or LLInt objects" {
    const allocator = std.testing.allocator;
    const objects = [_][]const u8{ jsc_main_object, jsc_llint_object };
    for ([_][]const u8{ "|", "||", "|@" }) |separator| {
        for (objects, 0..) |dependency, index| {
            const contents = try std.fmt.allocPrint(allocator, "{s}{s} {s} {s}\n{s}", .{
                jsc_ninja_prefix, objects[1 - index], separator, dependency, jsc_ninja_tail,
            });
            defer allocator.free(contents);
            try std.testing.expectError(
                error.BuildNinjaContractMismatch,
                buildtool.validateJscBuildNinja(contents, "Release"),
            );
        }
    }
}

// Build type remains an input rather than a fixed part of the embedding profile.
test "buildtool JSC native archive graph checks the selected build type" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "Debug", "RelWithDebInfo" }) |build_type| {
        const suffix = try std.fmt.allocPrint(allocator, "_{s}", .{build_type});
        defer allocator.free(suffix);
        const contents = try std.mem.replaceOwned(
            u8,
            allocator,
            standalone_build_ninja,
            "_Release",
            suffix,
        );
        defer allocator.free(contents);
        try buildtool.validateJscBuildNinja(contents, build_type);
        try std.testing.expectError(
            error.BuildNinjaContractMismatch,
            buildtool.validateJscBuildNinja(contents, "Release"),
        );
    }
}

test "buildtool JSC paths accept the deps layout without creating outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: [4][std.fs.max_path_bytes]u8 = undefined;
    const paths = try syntheticJscBuildPaths(tmp.dir, &storage);

    try buildtool.validateJscBuildPaths(paths);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(synthetic_generated ++ "/triple", .{}));
    try tmp.dir.makePath(synthetic_generated ++ "/triple/profile/src");
    try tmp.dir.makePath(synthetic_generated ++ "/triple/profile/build");
    try buildtool.validateJscBuildPaths(paths);
}

test "buildtool JSC paths reject overlapping outputs and anything outside the engine root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: [4][std.fs.max_path_bytes]u8 = undefined;
    const valid = try syntheticJscBuildPaths(tmp.dir, &storage);
    var paths = valid;
    paths.build = valid.worktree;
    try std.testing.expectError(error.OverlappingJscPaths, buildtool.validateJscBuildPaths(paths));

    var nested_buffer: [std.fs.max_path_bytes]u8 = undefined;
    paths = valid;
    paths.build = try std.fmt.bufPrint(&nested_buffer, "{s}/objects", .{valid.worktree});
    try std.testing.expectError(error.OverlappingJscPaths, buildtool.validateJscBuildPaths(paths));
    paths = valid;
    paths.worktree = valid.repository;
    try std.testing.expectError(error.GeneratedPathOutsideEngineRoot, buildtool.validateJscBuildPaths(paths));
    paths = valid;
    paths.build = valid.project_root;
    try std.testing.expectError(error.GeneratedPathOutsideEngineRoot, buildtool.validateJscBuildPaths(paths));
    paths = valid;
    paths.worktree = try std.fmt.bufPrint(&nested_buffer, "{s}/{s}", .{ valid.project_root, buildtool.engine_generated_relative });
    try std.testing.expectError(error.GeneratedPathOutsideEngineRoot, buildtool.validateJscBuildPaths(paths));
    paths = valid;
    paths.repository = try std.fmt.bufPrint(&nested_buffer, "{s}/runtime/deps/other", .{valid.project_root});
    try std.testing.expectError(error.EngineRepositoryPath, buildtool.validateJscBuildPaths(paths));
}

test "buildtool JSC paths reject symlink ancestors including dangling aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: [4][std.fs.max_path_bytes]u8 = undefined;
    const valid = try syntheticJscBuildPaths(tmp.dir, &storage);
    const deps = std.fs.path.dirname(valid.repository).?;
    try tmp.dir.symLink("WebKit", synthetic_deps ++ "/alias", .{ .is_directory = true });
    try tmp.dir.symLink("missing", synthetic_deps ++ "/dangling", .{ .is_directory = true });
    var alias_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var paths = valid;
    paths.repository = try std.fmt.bufPrint(&alias_buffer, "{s}/alias", .{deps});
    try std.testing.expectError(error.NonCanonicalPath, buildtool.validateJscBuildPaths(paths));
    paths = valid;
    paths.worktree = try std.fmt.bufPrint(&alias_buffer, "{s}/alias/generated", .{deps});
    try std.testing.expectError(error.NonCanonicalPath, buildtool.validateJscBuildPaths(paths));
    paths = valid;
    paths.build = try std.fmt.bufPrint(&alias_buffer, "{s}/dangling/generated", .{deps});
    try std.testing.expectError(error.NonCanonicalPath, buildtool.validateJscBuildPaths(paths));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(synthetic_deps ++ "/WebKit/generated", .{}));
}

test "buildtool JSC paths reject traversal relative paths and non-directory outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: [4][std.fs.max_path_bytes]u8 = undefined;
    const valid = try syntheticJscBuildPaths(tmp.dir, &storage);
    var paths = valid;
    paths.repository = "";
    try std.testing.expectError(error.NonCanonicalPath, buildtool.validateJscBuildPaths(paths));
    paths = valid;
    paths.worktree = "relative/source";
    try std.testing.expectError(error.NonCanonicalPath, buildtool.validateJscBuildPaths(paths));
    var invalid_buffer: [std.fs.max_path_bytes]u8 = undefined;
    paths = valid;
    paths.build = try std.fmt.bufPrint(&invalid_buffer, "{s}/../build", .{valid.worktree});
    try std.testing.expectError(error.NonCanonicalPath, buildtool.validateJscBuildPaths(paths));

    const file = try tmp.dir.createFile(synthetic_generated ++ "/file", .{});
    file.close();
    paths = valid;
    paths.build = try std.fmt.bufPrint(
        &invalid_buffer,
        "{s}/{s}/file/objects",
        .{ valid.project_root, buildtool.engine_generated_relative },
    );
    try std.testing.expectError(error.NotDirectory, buildtool.validateJscBuildPaths(paths));
}

test "buildtool archiveMatchesArch accepts matching synthetic archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSyntheticArchive(tmp.dir, "libsynthetic.a", x86_64_machine);
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "libsynthetic.a");
    defer std.testing.allocator.free(path);

    try std.testing.expect(try buildtool.archiveMatchesArch(
        std.testing.allocator,
        path,
        "x86_64",
    ));
}

test "buildtool archiveMatchesArch rejects mismatched and unsupported arch names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSyntheticArchive(tmp.dir, "libsynthetic.a", aarch64_machine);
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "libsynthetic.a");
    defer std.testing.allocator.free(path);

    try std.testing.expect(!try buildtool.archiveMatchesArch(
        std.testing.allocator,
        path,
        "x86_64",
    ));
    try std.testing.expect(!try buildtool.archiveMatchesArch(
        std.testing.allocator,
        path,
        "riscv64",
    ));
}

test "buildtool archiveMatchesArch validates every object member" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSyntheticArchiveMachines(
        tmp.dir,
        "libmixed.a",
        &.{ x86_64_machine, aarch64_machine },
    );
    const mixed = try tmp.dir.realpathAlloc(std.testing.allocator, "libmixed.a");
    defer std.testing.allocator.free(mixed);
    try std.testing.expect(!try buildtool.archiveMatchesArch(
        std.testing.allocator,
        mixed,
        "x86_64",
    ));

    const malformed = try tmp.dir.createFile("libsecond-not-elf.a", .{});
    try malformed.writeAll(archive_magic);
    const elf_header = syntheticElfHeader(x86_64_machine);
    try writeMemberHeader(malformed, "first.o/", elf_header.len);
    try malformed.writeAll(&elf_header);
    try writeMemberHeader(malformed, "second.o/", 20);
    try malformed.writeAll("not-an-elf-member!!!");
    malformed.close();
    const malformed_path = try tmp.dir.realpathAlloc(std.testing.allocator, "libsecond-not-elf.a");
    defer std.testing.allocator.free(malformed_path);
    try std.testing.expectError(
        error.ElfTooShort,
        buildtool.archiveMatchesArch(std.testing.allocator, malformed_path, "x86_64"),
    );

    const disguised = try tmp.dir.createFile("libsymdef-prefix.a", .{});
    try disguised.writeAll(archive_magic);
    try writeMemberHeader(disguised, "first.o/", elf_header.len);
    try disguised.writeAll(&elf_header);
    // ".o" suffix keeps this past the member-name gate (which now rejects
    // non-".o" names outright) so the symdef-prefix disguise still has to
    // clear ELF inspection, which is what this case exercises.
    try writeMemberHeader(disguised, "__.SYMDEFEVIL.o", 0);
    disguised.close();
    const disguised_path = try tmp.dir.realpathAlloc(std.testing.allocator, "libsymdef-prefix.a");
    defer std.testing.allocator.free(disguised_path);
    try std.testing.expectError(
        error.ElfTooShort,
        buildtool.archiveMatchesArch(std.testing.allocator, disguised_path, "x86_64"),
    );
}

test "buildtool archiveMatchesArch rejects noncanonical size trailer and padding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const elf_header = syntheticElfHeader(x86_64_machine);
    {
        const file = try tmp.dir.createFile("negative-size.a", .{});
        defer file.close();
        try file.writeAll(archive_magic);
        var header = [_]u8{' '} ** 60;
        @memcpy(header[0..9], "object.o/");
        @memcpy(header[48..58], "-1        ");
        @memcpy(header[58..60], "`\n");
        try file.writeAll(&header);
    }
    {
        const file = try tmp.dir.createFile("leading-zero-size.a", .{});
        defer file.close();
        try file.writeAll(archive_magic);
        var header = [_]u8{' '} ** 60;
        @memcpy(header[0..9], "object.o/");
        @memcpy(header[48..58], "020       ");
        @memcpy(header[58..60], "`\n");
        try file.writeAll(&header);
    }
    {
        const file = try tmp.dir.createFile("bad-trailer.a", .{});
        defer file.close();
        try file.writeAll(archive_magic);
        try writeMemberHeader(file, "object.o/", elf_header.len);
        try file.writeAll(&elf_header);
        try file.seekTo(8 + 58);
        try file.writeAll("xx");
    }
    {
        const file = try tmp.dir.createFile("bad-padding.a", .{});
        defer file.close();
        try file.writeAll(archive_magic);
        try writeMemberHeader(file, "object.o/", elf_header.len + 1);
        try file.writeAll(&elf_header);
        try file.writeAll(&.{0});
        try file.writeAll("X");
    }

    const negative = try tmp.dir.realpathAlloc(std.testing.allocator, "negative-size.a");
    defer std.testing.allocator.free(negative);
    try std.testing.expectError(
        error.ArchiveMemberSizeInvalid,
        buildtool.archiveMatchesArch(std.testing.allocator, negative, "x86_64"),
    );
    const leading_zero = try tmp.dir.realpathAlloc(std.testing.allocator, "leading-zero-size.a");
    defer std.testing.allocator.free(leading_zero);
    try std.testing.expectError(
        error.ArchiveMemberSizeInvalid,
        buildtool.archiveMatchesArch(std.testing.allocator, leading_zero, "x86_64"),
    );
    const trailer = try tmp.dir.realpathAlloc(std.testing.allocator, "bad-trailer.a");
    defer std.testing.allocator.free(trailer);
    try std.testing.expectError(
        error.ArchiveHeaderInvalid,
        buildtool.archiveMatchesArch(std.testing.allocator, trailer, "x86_64"),
    );
    const padding = try tmp.dir.realpathAlloc(std.testing.allocator, "bad-padding.a");
    defer std.testing.allocator.free(padding);
    try std.testing.expectError(
        error.ArchivePaddingInvalid,
        buildtool.archiveMatchesArch(std.testing.allocator, padding, "x86_64"),
    );
}

test "buildtool archiveMatchesArch maps malformed archives to errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("bad.a", .{});
        defer file.close();
        try file.writeAll("not-an-archive");
    }

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "bad.a");
    defer std.testing.allocator.free(path);
    try std.testing.expectError(
        error.ArchiveBadMagic,
        buildtool.archiveMatchesArch(std.testing.allocator, path, "x86_64"),
    );
}

test "buildtool archiveMatchesArch rejects aliases hardlinks and traversal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSyntheticArchive(tmp.dir, "direct.a", x86_64_machine);
    const direct = try tmp.dir.realpathAlloc(std.testing.allocator, "direct.a");
    defer std.testing.allocator.free(direct);
    const alias = try std.fs.path.join(std.testing.allocator, &.{
        std.fs.path.dirname(direct).?, "alias.a",
    });
    defer std.testing.allocator.free(alias);
    try tmp.dir.symLink("direct.a", "alias.a", .{});
    // A symlinked final path component fails the O_NOFOLLOW open itself.
    try std.testing.expectError(
        error.SymLinkLoop,
        buildtool.archiveMatchesArch(std.testing.allocator, alias, "x86_64"),
    );
    try tmp.dir.deleteFile("alias.a");

    try tmp.dir.symLink(".", "directory-alias", .{ .is_directory = true });
    const component_alias = try std.fs.path.join(std.testing.allocator, &.{
        std.fs.path.dirname(direct).?, "directory-alias", "direct.a",
    });
    defer std.testing.allocator.free(component_alias);
    // The open succeeds (O_NOFOLLOW only guards the final component), but the
    // /proc/self/fd realpath no longer matches the given path, so this is
    // caught by the physical-path canonicalization check instead.
    try std.testing.expectError(
        error.NonCanonicalPath,
        buildtool.archiveMatchesArch(std.testing.allocator, component_alias, "x86_64"),
    );
    try tmp.dir.deleteFile("directory-alias");

    const hardlink = try std.fs.path.join(std.testing.allocator, &.{
        std.fs.path.dirname(direct).?, "hardlink.a",
    });
    defer std.testing.allocator.free(hardlink);
    try std.posix.link(direct, hardlink);
    try std.testing.expectError(
        error.MultipleHardLinks,
        buildtool.archiveMatchesArch(std.testing.allocator, hardlink, "x86_64"),
    );
    try tmp.dir.deleteFile("hardlink.a");

    try tmp.dir.makeDir("sub");
    const traversal = try std.fs.path.join(std.testing.allocator, &.{
        std.fs.path.dirname(direct).?, "sub", "..", "direct.a",
    });
    defer std.testing.allocator.free(traversal);
    // Caught by the ".." component scan before any open() call.
    try std.testing.expectError(
        error.NonCanonicalPath,
        buildtool.archiveMatchesArch(std.testing.allocator, traversal, "x86_64"),
    );
}

const synthetic_deps = "project/runtime/deps";
const synthetic_generated = "project/" ++ buildtool.engine_generated_relative;

/// A project root with the deps layout the tool requires: the clone at
/// `runtime/deps/WebKit` and generated directories under `runtime/deps/jsc-build`.
fn syntheticJscBuildPaths(
    dir: std.fs.Dir,
    storage: *[4][std.fs.max_path_bytes]u8,
) !buildtool.JscBuildPaths {
    try dir.makePath("project/" ++ buildtool.webkit_repository_relative);
    try dir.makePath(synthetic_generated);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &root_buffer);
    return .{
        .project_root = try std.fmt.bufPrint(&storage[0], "{s}/project", .{root}),
        .repository = try std.fmt.bufPrint(&storage[1], "{s}/project/{s}", .{ root, buildtool.webkit_repository_relative }),
        .worktree = try std.fmt.bufPrint(&storage[2], "{s}/{s}/triple/profile/src", .{ root, synthetic_generated }),
        .build = try std.fmt.bufPrint(&storage[3], "{s}/{s}/triple/profile/build", .{ root, synthetic_generated }),
    };
}

fn writeSyntheticArchive(dir: std.fs.Dir, name: []const u8, machine: u16) !void {
    return writeSyntheticArchiveMachines(dir, name, &.{machine});
}

fn syntheticElfHeader(machine: u16) [64]u8 {
    var elf_header = [_]u8{0} ** 64;
    elf_header[0] = 0x7f;
    elf_header[1] = 'E';
    elf_header[2] = 'L';
    elf_header[3] = 'F';
    elf_header[4] = 2;
    elf_header[5] = 1;
    elf_header[6] = 1;
    std.mem.writeInt(u16, elf_header[16..18], 1, .little);
    std.mem.writeInt(u16, elf_header[18..20], machine, .little);
    std.mem.writeInt(u32, elf_header[20..24], 1, .little);
    std.mem.writeInt(u16, elf_header[52..54], 64, .little);
    return elf_header;
}

fn writeSyntheticArchiveMachines(
    dir: std.fs.Dir,
    name: []const u8,
    machines: []const u16,
) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();

    try file.writeAll(archive_magic);
    for (machines, 0..) |machine, index| {
        var member_name: [16]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&member_name, "object{d}.o/", .{index});
        const elf_header = syntheticElfHeader(machine);
        try writeMemberHeader(file, rendered, elf_header.len);
        try file.writeAll(&elf_header);
    }
}

fn writeMemberHeader(file: std.fs.File, name: []const u8, size: usize) !void {
    var header = [_]u8{' '} ** 60;
    @memcpy(header[0..name.len], name);
    @memcpy(header[16..17], "0");
    @memcpy(header[28..29], "0");
    @memcpy(header[34..35], "0");
    @memcpy(header[40..43], "644");
    const size_text = try std.fmt.bufPrint(header[48..58], "{d}", .{size});
    @memset(header[48 + size_text.len .. 58], ' ');
    header[58] = '`';
    header[59] = '\n';
    try file.writeAll(&header);
}
