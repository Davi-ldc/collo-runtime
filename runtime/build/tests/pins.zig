//! The pins the build script and the buildtool share: the version-file
//! parser (`runtime/build/pins.zig`), every version file in `runtime/deps/`,
//! the native build directory names (`buildtool.nativeBuildKey`) and the
//! FindICU entries the engine's CMake receives. Lane: `meta-test`. Fetching,
//! verifying and building the trees needs git, CMake and the network, so the
//! `deps-provision`, `icu` and `boringssl` steps exercise those paths.

const std = @import("std");
const buildtool = @import("collo_buildtool");
const pins = buildtool.pins;

const commit = "0123456789abcdef0123456789abcdef01234567";

test "a version file header parses into its pin, and the prose after it is never read" {
    const pin = try pins.parse("Source: https://example.org/dep.git\n" ++
        "Tag: v1.2.3\n" ++
        "Commit: " ++ commit ++ "\n" ++
        "Patches: patches/dep\n" ++
        "\n" ++
        "Prose: with a colon, and Commit: not-a-commit, is not a field.\n");
    try std.testing.expectEqualStrings("https://example.org/dep.git", pin.source);
    try std.testing.expectEqualStrings("v1.2.3", pin.tag.?);
    try std.testing.expectEqualStrings(commit, pin.commit);
    try std.testing.expectEqualStrings("patches/dep", pin.patches.?);

    const untagged = try pins.parse("Source: https://example.org/dep.git\n" ++
        "Commit: " ++ commit ++ "\n" ++
        "Patches: none\n");
    try std.testing.expectEqual(@as(?[]const u8, null), untagged.tag);
    try std.testing.expectEqual(@as(?[]const u8, null), untagged.patches);
}

test "a version file with a malformed commit, a repeated or unknown key, a carriage return or a missing field is refused" {
    const header = "Source: https://example.org/dep.git\nPatches: none\n";
    const cases = [_]struct { text: []const u8, expected: pins.ParseError }{
        .{ .text = header ++ "Commit: 0123456789abcdef\n", .expected = error.MalformedCommit },
        .{ .text = header ++ "Commit: 0123456789ABCDEF0123456789abcdef01234567\n", .expected = error.MalformedCommit },
        .{ .text = header ++ "Commit: " ++ commit ++ "\nCommit: " ++ commit ++ "\n", .expected = error.DuplicateField },
        .{ .text = header ++ "Commit: " ++ commit ++ "\nBranch: main\n", .expected = error.UnknownField },
        .{ .text = header ++ "Commit: " ++ commit ++ "\r\n", .expected = error.MalformedLine },
        .{ .text = header ++ "Commit:\n", .expected = error.EmptyValue },
        .{ .text = header ++ "Commit " ++ commit ++ "\n", .expected = error.MalformedLine },
        .{ .text = header, .expected = error.MissingField },
        .{ .text = "Source: https://example.org/dep.git\nCommit: " ++ commit ++ "\n", .expected = error.MissingField },
        .{ .text = "Commit: " ++ commit ++ "\nPatches: none\n", .expected = error.MissingField },
    };
    for (cases) |case|
        try std.testing.expectError(case.expected, pins.parse(case.text));
}

test "every pinned dependency's version file parses, and the trees they name are distinct" {
    const gpa = std.testing.allocator;
    for (std.enums.values(pins.Dependency), 0..) |dependency, index| {
        var loaded = try pins.load(gpa, std.fs.cwd(), dependency);
        defer loaded.deinit(gpa);
        try std.testing.expect(pins.isFullCommit(loaded.pin.commit));
        try std.testing.expect(std.mem.startsWith(u8, loaded.pin.source, "https://"));
        if (loaded.pin.patches) |patches|
            try std.testing.expect(std.mem.startsWith(u8, patches, "patches/"));
        for (std.enums.values(pins.Dependency)[index + 1 ..]) |other|
            try std.testing.expect(!std.mem.eql(u8, pins.spec(dependency).tree, pins.spec(other).tree));
    }
}

test "a native build directory is the target triple, plus the CPU model when one is pinned" {
    const gpa = std.testing.allocator;
    const native = try buildtool.nativeBuildKey(gpa, "x86_64-linux-gnu", "");
    defer gpa.free(native);
    try std.testing.expectEqualStrings("x86_64-linux-gnu", native);
    const pinned = try buildtool.nativeBuildKey(gpa, "aarch64-linux-gnu", "neoverse_n1");
    defer gpa.free(pinned);
    try std.testing.expectEqualStrings("aarch64-linux-gnu-neoverse_n1", pinned);
}

test "the engine's FindICU entries name every ICU archive the link names, under the install prefix" {
    for (buildtool.icu_build.archives) |archive| {
        var named = false;
        for (buildtool.icu_build.cmake_cache_entries) |entry| {
            const suffix = entry.prefix_suffix;
            if (suffix.len == archive.len + 1 and suffix[0] == '/' and std.mem.eql(u8, suffix[1..], archive))
                named = true;
        }
        try std.testing.expect(named);
    }
    // Static archives resolve left to right, so data, which nothing else
    // needs, comes last and i18n, which needs uc, comes first.
    try std.testing.expectEqualStrings("lib/libicui18n.a", buildtool.icu_build.archives[0]);
    try std.testing.expectEqualStrings("lib/libicudata.a", buildtool.icu_build.archives[2]);
}
