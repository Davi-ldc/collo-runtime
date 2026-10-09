//! zstd is a core module-pack dependency. Production links it statically; the
//! default `auto` resolves per-toolchain capability (static when libzstd.a
//! exists, else the system shared object) so plain `zig build <step>` works on
//! dev machines — the release steps reject anything that resolved non-static.
const std = @import("std");
const toolchain_mod = @import("toolchain.zig");

pub const LinkMode = enum {
    static,
    system_dynamic,
};

/// What the -D flag accepts; `auto` collapses to a LinkMode in
/// `resolveChoice` once the toolchain paths are known.
pub const LinkChoice = enum {
    auto,
    static,
    system_dynamic,
};

pub fn parseLinkChoice(value: []const u8) ?LinkChoice {
    if (std.mem.eql(u8, value, "auto"))
        return .auto;
    if (std.mem.eql(u8, value, "static"))
        return .static;
    if (std.mem.eql(u8, value, "system-dynamic"))
        return .system_dynamic;
    if (std.mem.eql(u8, value, "system_dynamic"))
        return .system_dynamic;
    return null;
}

/// Collapse `auto` against the discovered toolchain: static when libzstd.a is
/// present, else system-dynamic (dev machines rarely carry the static lib).
/// Explicit choices pass through untouched — including into failure, so a
/// pinned mode never silently degrades.
pub fn resolveChoice(
    b: *std.Build,
    toolchain: *const toolchain_mod.ToolchainPaths,
    choice: LinkChoice,
) LinkMode {
    switch (choice) {
        .static => return .static,
        .system_dynamic => return .system_dynamic,
        .auto => {
            if (resolve(b, toolchain, .static) != null)
                return .static;
            return .system_dynamic;
        },
    }
}

pub fn addToModule(
    b: *std.Build,
    module: *std.Build.Module,
    toolchain: *const toolchain_mod.ToolchainPaths,
    mode: LinkMode,
) void {
    const path = resolveRequired(b, toolchain, mode);
    module.addObjectFile(.{ .cwd_relative = path });
}

pub fn addToCxxLink(
    b: *std.Build,
    link: *std.Build.Step.Run,
    toolchain: *const toolchain_mod.ToolchainPaths,
    mode: LinkMode,
) void {
    const path = resolveRequired(b, toolchain, mode);
    link.addFileArg(.{ .cwd_relative = path });
}

fn resolveRequired(
    b: *std.Build,
    toolchain: *const toolchain_mod.ToolchainPaths,
    mode: LinkMode,
) []const u8 {
    if (resolve(b, toolchain, mode)) |path|
        return path;

    const expected = switch (mode) {
        .static => "libzstd.a",
        .system_dynamic => "libzstd.so.1 or libzstd.so",
    };
    std.process.fatal(
        "missing {s} in {s} or {s}; install zstd for the target sysroot" ++
            " or use -Dzstd-link=system-dynamic for local development",
        .{ expected, toolchain.crt_dir, toolchain.lib_dir },
    );
}

fn resolve(
    b: *std.Build,
    toolchain: *const toolchain_mod.ToolchainPaths,
    mode: LinkMode,
) ?[]const u8 {
    const names = switch (mode) {
        .static => &[_][]const u8{"libzstd.a"},
        .system_dynamic => &[_][]const u8{ "libzstd.so.1", "libzstd.so" },
    };
    const roots = [_][]const u8{
        toolchain.crt_dir,
        toolchain.lib_dir,
    };
    for (roots) |root| {
        for (names) |name| {
            const path = b.pathJoin(&.{ root, name });
            std.fs.cwd().access(path, .{}) catch continue;
            return path;
        }
    }
    return null;
}
