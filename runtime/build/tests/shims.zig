// Pin JSC include roots and consumer ABI flags without compiling or linking the engine.
const std = @import("std");
const shims = @import("collo_build_shims");

test "JSC bridge include roots support qualified and bare header names" {
    for ([_][]const u8{
        "JavaScriptCore/Headers",
        "JavaScriptCore/Headers/JavaScriptCore",
        "JavaScriptCore/PrivateHeaders",
        "JavaScriptCore/PrivateHeaders/JavaScriptCore",
    }) |required| {
        var found = false;
        for (shims.jsc_include_suffixes) |suffix| {
            if (std.mem.eql(u8, required, suffix)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "JSC bridge include roots retain one build root and unique relative suffixes" {
    try std.testing.expectEqualStrings("", shims.jsc_include_suffixes[0]);
    for (shims.jsc_include_suffixes, 0..) |suffix, index| {
        if (index != 0)
            try std.testing.expect(suffix.len != 0);
        try std.testing.expect(!std.fs.path.isAbsolute(suffix));
        for (shims.jsc_include_suffixes[index + 1 ..]) |other|
            try std.testing.expect(!std.mem.eql(u8, suffix, other));
    }
}

test "JSC C++ flags select the engine Debug and Release ABIs" {
    const common_flags = [_][]const u8{
        "-std=c++23",
        "-fno-exceptions",
        "-fno-rtti",
        "-DBUILDING_WITH_CMAKE=1",
        "-DHAVE_CONFIG_H=1",
    };
    const cases = [_]struct {
        cmake_build_type: []const u8,
        abi_flags: []const []const u8,
    }{
        .{
            .cmake_build_type = "Debug",
            .abi_flags = &.{ "-UNDEBUG", "-DENABLE_EXCEPTION_SCOPE_VERIFICATION=1" },
        },
        .{
            .cmake_build_type = "Release",
            .abi_flags = &.{
                "-DNDEBUG",
                "-DENABLE_EXCEPTION_SCOPE_VERIFICATION=0",
                "-DRELEASE_WITHOUT_OPTIMIZATIONS=1",
            },
        },
    };
    for (cases) |case| {
        const flags = try shims.bindingCFlags(case.cmake_build_type);
        try std.testing.expectEqual(common_flags.len + case.abi_flags.len, flags.len);
        for (common_flags, flags[0..common_flags.len]) |expected, actual|
            try std.testing.expectEqualStrings(expected, actual);
        for (case.abi_flags, flags[common_flags.len..]) |expected, actual|
            try std.testing.expectEqualStrings(expected, actual);
    }
}

test "JSC C++ flags reject unsupported engine modes" {
    for ([_][]const u8{
        "", "debug", "release", "RelWithDebInfo", "MinSizeRel", "ReleaseSafe", "ReleaseFast",
    }) |mode| {
        try std.testing.expectError(error.UnsupportedJscBuildType, shims.bindingCFlags(mode));
    }
}

test "JSC Release ABI selection preserves bridge ASan instrumentation" {
    const sanitizer = shims.BindingsSanitizer{ .mode = .address_leak };
    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(std.testing.allocator);
    try flags.appendSlice(std.testing.allocator, try shims.bindingCFlags("Release"));
    try flags.appendSlice(std.testing.allocator, sanitizer.cFlags());

    const expected = [_][]const u8{
        "-std=c++23",
        "-fno-exceptions",
        "-fno-rtti",
        "-DBUILDING_WITH_CMAKE=1",
        "-DHAVE_CONFIG_H=1",
        "-DNDEBUG",
        "-DENABLE_EXCEPTION_SCOPE_VERIFICATION=0",
        "-DRELEASE_WITHOUT_OPTIMIZATIONS=1",
        "-fsanitize=address,leak",
        "-fno-omit-frame-pointer",
        "-g",
    };
    try std.testing.expectEqual(expected.len, flags.items.len);
    for (expected, flags.items) |expected_flag, actual_flag|
        try std.testing.expectEqualStrings(expected_flag, actual_flag);
}
