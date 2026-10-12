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

test "the undefined-behavior mode aborts on misaligned reads and float casts in the C++ and leaves Zig alone" {
    const sanitizer = shims.parseBindingsSanitizer("undefined");
    try std.testing.expectEqual(shims.BindingsSanitizerMode.undefined_behavior, sanitizer.mode);
    try std.testing.expect(!sanitizer.instrumentsZig());

    const expected_compile = [_][]const u8{
        "-fsanitize=alignment,float-cast-overflow",
        "-fno-sanitize-recover=alignment,float-cast-overflow",
        "-fno-sanitize-trap=alignment,float-cast-overflow",
        "-fno-omit-frame-pointer",
        "-g",
    };
    const compile_flags = sanitizer.cFlags();
    try std.testing.expectEqual(expected_compile.len, compile_flags.len);
    for (expected_compile, compile_flags) |expected_flag, actual_flag|
        try std.testing.expectEqualStrings(expected_flag, actual_flag);

    // The link names the same checks, so the driver adds their runtime.
    try std.testing.expectEqualStrings("-fsanitize=alignment,float-cast-overflow", sanitizer.linkArgs()[0]);
    const env = sanitizer.runEnv() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("UBSAN_OPTIONS", env.key);
}

test "every sanitizer spelling selects its mode, and only ASan instruments Zig" {
    const cases = [_]struct { name: []const u8, mode: shims.BindingsSanitizerMode }{
        .{ .name = "none", .mode = .none },
        .{ .name = "address", .mode = .address_leak },
        .{ .name = "address,leak", .mode = .address_leak },
        .{ .name = "asan", .mode = .address_leak },
        .{ .name = "asan,lsan", .mode = .address_leak },
        .{ .name = "undefined", .mode = .undefined_behavior },
        .{ .name = "ubsan", .mode = .undefined_behavior },
    };
    for (cases) |case| {
        const sanitizer = shims.parseBindingsSanitizer(case.name);
        try std.testing.expectEqual(case.mode, sanitizer.mode);
        try std.testing.expectEqual(case.mode == .address_leak, sanitizer.instrumentsZig());
    }
    try std.testing.expectEqual(@as(usize, 0), shims.parseBindingsSanitizer("none").cFlags().len);
    try std.testing.expect(shims.parseBindingsSanitizer("none").runEnv() == null);
}
