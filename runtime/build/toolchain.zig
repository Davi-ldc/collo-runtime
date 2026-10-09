//! Host/target C++ toolchain discovery for the JSC bridge and the final link.
//! Pinned constants with env escape hatches (see options.zig); nothing here is
//! part of the -D surface.
const std = @import("std");
const builtin = @import("builtin");
const shims = @import("shims.zig");

pub const ToolchainPaths = struct {
    zig_exe: []const u8,
    native_cxx_linker: []const u8,
    use_zig_cxx_linker: bool,
    cxx_stdlib_include_dir: []const u8,
    cxx_stdlib_arch_include_dir: []const u8,
    cxx_stdlib_backward_include_dir: []const u8,
    zig_include_dir: []const u8,
    zig_libc_arch_include_dir: []const u8,
    zig_libc_generic_include_dir: []const u8,
    zig_libc_arch_any_include_dir: []const u8,
    zig_libc_any_linux_include_dir: []const u8,
    sys_include_dir: []const u8,
    include_root: []const u8,
    crt_dir: []const u8,
    lib_dir: []const u8,
    compiler_rt_builtins_path: ?[]const u8,
    /// Sysroot GNU libstdc++.a for cross links. `zig c++` maps -lstdc++ to
    /// its bundled libc++ — the wrong ABI for objects compiled against the
    /// sysroot's GNU libstdc++ headers — so cross links must name this
    /// archive explicitly. Null when linking natively.
    cxx_stdlib_static_archive: ?[]const u8,
    target_triple: []const u8,
    /// Triple for the `zig c++` FINAL LINK only — may carry a glibc version
    /// suffix (COLLO_TARGET_GLIBC), which zig cc understands and clang does
    /// not. Everything clang-facing uses `target_triple`.
    link_target_triple: []const u8,
    target_mcpu: ?[]const u8,
    /// The sysroot's `sys/cdefs.h` predates glibc 2.36 and lacks `__COLD`
    /// (see `cxxFlagsWithTarget`).
    needs_cold_macro: bool,

    pub fn systemIncludeDirs(self: *const ToolchainPaths) [10][]const u8 {
        return .{
            self.cxx_stdlib_include_dir,
            self.cxx_stdlib_arch_include_dir,
            self.cxx_stdlib_backward_include_dir,
            self.zig_include_dir,
            self.zig_libc_arch_include_dir,
            self.zig_libc_generic_include_dir,
            self.zig_libc_arch_any_include_dir,
            self.zig_libc_any_linux_include_dir,
            self.sys_include_dir,
            self.include_root,
        };
    }
};

/// Null when the target needs a sysroot we do not have (cross compile without
/// COLLO_CXX_SYSROOT); callers turn that into fail-steps instead of killing
/// the whole configure.
pub fn discover(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    cxx_stdlib_version: []const u8,
    cxx_sysroot: []const u8,
    native_cxx_linker: []const u8,
    compiler_rt_builtins: ?[]const u8,
) ?ToolchainPaths {
    const zig_lib_dir = b.graph.zig_lib_directory.path orelse
        std.process.fatal("zig lib directory path is unavailable", .{});
    const use_zig_cxx_linker = shouldUseZigCxxLinker(target);
    if (use_zig_cxx_linker and cxx_sysroot.len == 0)
        return null;
    const multiarch = targetMultiarch(target.result);
    const zig_libc_arch = zigLibcArchName(target.result.cpu.arch);
    const include_root = if (cxx_sysroot.len == 0) "/usr/include" else b.pathJoin(&.{ cxx_sysroot, "usr/include" });
    const stdlib_version = resolveCxxStdlibVersion(b, include_root, multiarch, cxx_stdlib_version);
    const lib_root = if (cxx_sysroot.len == 0) "/usr/lib" else b.pathJoin(&.{ cxx_sysroot, "usr/lib" });
    const root_lib_root = if (cxx_sysroot.len == 0) "/lib" else b.pathJoin(&.{ cxx_sysroot, "lib" });
    const target_triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
    // `zig c++` resolves an unversioned gnu triple against its oldest
    // supported glibc stubs, which lack newer symbols the code uses (e.g.
    // posix_spawn_file_actions_addclosefrom_np, glibc 2.34+). Cross links
    // pin the fleet's actual glibc floor via COLLO_TARGET_GLIBC — only the
    // link triple: clang rejects glibc-versioned triples, so the compile
    // flags keep the plain one.
    const link_target_triple = if (b.graph.env_map.get("COLLO_TARGET_GLIBC")) |glibc|
        b.fmt("{s}.{s}", .{ target_triple, glibc })
    else
        target_triple;
    const target_mcpu = if (target.query.isNative()) null else blk: {
        const serialized = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
        break :blk if (serialized.len == 0 or std.mem.eql(u8, serialized, "baseline"))
            null
        else
            serialized;
    };

    return .{
        .zig_exe = b.graph.zig_exe,
        .native_cxx_linker = native_cxx_linker,
        .use_zig_cxx_linker = use_zig_cxx_linker,
        .cxx_stdlib_include_dir = b.pathJoin(&.{ include_root, "c++", stdlib_version }),
        .cxx_stdlib_arch_include_dir = b.pathJoin(&.{ include_root, multiarch, "c++", stdlib_version }),
        .cxx_stdlib_backward_include_dir = b.pathJoin(&.{ include_root, "c++", stdlib_version, "backward" }),
        .zig_include_dir = b.pathJoin(&.{ zig_lib_dir, "include" }),
        .zig_libc_arch_include_dir = b.pathJoin(&.{ zig_lib_dir, "libc/include", b.fmt("{s}-linux-gnu", .{zig_libc_arch}) }),
        .zig_libc_generic_include_dir = b.pathJoin(&.{ zig_lib_dir, "libc/include/generic-glibc" }),
        .zig_libc_arch_any_include_dir = b.pathJoin(&.{ zig_lib_dir, "libc/include", b.fmt("{s}-linux-any", .{zig_libc_arch}) }),
        .zig_libc_any_linux_include_dir = b.pathJoin(&.{ zig_lib_dir, "libc/include/any-linux-any" }),
        .sys_include_dir = b.pathJoin(&.{ include_root, multiarch }),
        .include_root = include_root,
        .crt_dir = b.pathJoin(&.{ lib_root, multiarch }),
        .lib_dir = b.pathJoin(&.{ root_lib_root, multiarch }),
        .compiler_rt_builtins_path = compiler_rt_builtins,
        .cxx_stdlib_static_archive = if (cxx_sysroot.len == 0)
            null
        else
            b.pathJoin(&.{ lib_root, "gcc", multiarch, stdlib_version, "libstdc++.a" }),
        .link_target_triple = link_target_triple,
        .target_triple = target_triple,
        .target_mcpu = target_mcpu,
        .needs_cold_macro = !sysrootDefinesColdMacro(b, include_root, multiarch),
    };
}

fn sysrootDefinesColdMacro(b: *std.Build, include_root: []const u8, multiarch: []const u8) bool {
    const path = b.pathJoin(&.{ include_root, multiarch, "sys/cdefs.h" });
    const contents = std.fs.cwd().readFileAlloc(b.allocator, path, 512 * 1024) catch return false;
    defer b.allocator.free(contents);
    return std.mem.indexOf(u8, contents, "define __COLD") != null;
}

pub fn createLibcConfig(b: *std.Build, toolchain: *const ToolchainPaths) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    return write_files.add("collo-zig-libc.conf", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ toolchain.include_root, toolchain.sys_include_dir, toolchain.crt_dir }));
}

/// The one place that decides which libstdc++ headers the C++ side compiles
/// against. `requested` (COLLO_CXX_STDLIB_VERSION) wins when it is actually
/// installed; otherwise the highest version present under the sysroot with
/// BOTH the generic and the arch-specific include dirs. A guessed version
/// that is not installed surfaces hundreds of lines into a WebKit header
/// ("no member named 'abort' in namespace 'std'"), which is why this fails
/// loudly here instead.
fn resolveCxxStdlibVersion(
    b: *std.Build,
    include_root: []const u8,
    multiarch: []const u8,
    requested: []const u8,
) []const u8 {
    if (cxxStdlibVersionInstalled(b, include_root, multiarch, requested))
        return requested;

    var best: ?[]const u8 = null;
    var best_value: u32 = 0;
    var dir = std.fs.cwd().openDir(b.pathJoin(&.{ include_root, "c++" }), .{ .iterate = true }) catch
        std.process.fatal(
            "no C++ standard library headers under {s}/c++ (wanted version {s}); install libstdc++-<n>-dev or set COLLO_CXX_STDLIB_VERSION",
            .{ include_root, requested },
        );
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        const value = std.fmt.parseUnsigned(u32, entry.name, 10) catch continue;
        if (value <= best_value) continue;
        const candidate = b.dupe(entry.name);
        if (!cxxStdlibVersionInstalled(b, include_root, multiarch, candidate)) continue;
        best = candidate;
        best_value = value;
    }

    const resolved = best orelse std.process.fatal(
        "libstdc++ {s} is not installed under {s} and no usable version was found; install libstdc++-{s}-dev or set COLLO_CXX_STDLIB_VERSION",
        .{ requested, include_root, requested },
    );
    std.log.warn(
        "libstdc++ {s} not installed under {s}; building against {s}",
        .{ requested, include_root, resolved },
    );
    return resolved;
}

fn cxxStdlibVersionInstalled(
    b: *std.Build,
    include_root: []const u8,
    multiarch: []const u8,
    version: []const u8,
) bool {
    // Both halves are required: the generic headers carry the declarations,
    // the arch dir carries bits/c++config.h. One without the other compiles
    // into confusing failures rather than a missing-file error.
    std.fs.cwd().access(b.pathJoin(&.{ include_root, "c++", version, "cstdlib" }), .{}) catch return false;
    std.fs.cwd().access(b.pathJoin(&.{ include_root, multiarch, "c++", version, "bits/c++config.h" }), .{}) catch return false;
    return true;
}

fn zigLibcArchName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => std.process.fatal("unsupported target arch for Zig libc include paths: {s}", .{@tagName(arch)}),
    };
}

pub fn targetMultiarch(target: std.Target) []const u8 {
    if (target.os.tag != .linux or !target.abi.isGnu())
        std.process.fatal("Collo JSC/libstdc++ build currently supports linux-gnu targets only, got {s}-{s}", .{ @tagName(target.os.tag), @tagName(target.abi) });
    return switch (target.cpu.arch) {
        .x86_64 => "x86_64-linux-gnu",
        .aarch64 => "aarch64-linux-gnu",
        else => std.process.fatal("unsupported target arch for Collo JSC/libstdc++ build: {s}", .{@tagName(target.cpu.arch)}),
    };
}

pub fn compilerRtArchName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => std.process.fatal("unsupported target arch for compiler-rt builtins: {s}", .{@tagName(arch)}),
    };
}

fn shouldUseZigCxxLinker(target: std.Build.ResolvedTarget) bool {
    if (target.query.isNative())
        return false;

    const host = builtin.target;
    return target.result.cpu.arch != host.cpu.arch or
        target.result.os.tag != host.os.tag or
        target.result.abi != host.abi;
}

pub fn addCxxLinkCommand(b: *std.Build, toolchain: *const ToolchainPaths) *std.Build.Step.Run {
    if (toolchain.use_zig_cxx_linker)
        return b.addSystemCommand(&.{ toolchain.zig_exe, "c++" });
    return b.addSystemCommand(&.{toolchain.native_cxx_linker});
}

pub fn addCxxTargetArgs(command: *std.Build.Step.Run, toolchain: *const ToolchainPaths) void {
    if (toolchain.use_zig_cxx_linker) {
        command.addArg("-target");
        command.addArg(toolchain.link_target_triple);
        if (toolchain.target_mcpu) |mcpu| {
            command.addArg("-mcpu");
            command.addArg(mcpu);
        }
    }
    command.addArg("-L");
    command.addArg(toolchain.crt_dir);
    command.addArg("-L");
    command.addArg(toolchain.lib_dir);
}

pub fn cxxFlagsWithTarget(
    b: *std.Build,
    toolchain: *const ToolchainPaths,
    base_flags: []const []const u8,
    sanitizer: shims.BindingsSanitizer,
) []const []const u8 {
    var flags = std.array_list.Aligned([]const u8, null).empty;
    flags.appendSlice(b.allocator, base_flags) catch @panic("OOM");
    // Zig ships glibc headers newer than some sysroots': its `stdlib.h`
    // declares `abort` with `__COLD`, a macro glibc only added to
    // `sys/cdefs.h` in 2.36. On an older sysroot the declaration expands to
    // a bare identifier and the failure surfaces as a wall of C++ errors
    // ("no member named 'abort' in namespace 'std'") far from the cause.
    // The definition is textually glibc's own, so a sysroot that does define
    // it redefines it identically and clang stays quiet.
    if (toolchain.needs_cold_macro)
        flags.append(b.allocator, "-D__COLD=__attribute__((__cold__))") catch @panic("OOM");
    flags.appendSlice(b.allocator, sanitizer.cFlags()) catch @panic("OOM");
    flags.append(b.allocator, "-target") catch @panic("OOM");
    flags.append(b.allocator, toolchain.target_triple) catch @panic("OOM");
    if (toolchain.target_mcpu) |mcpu| {
        flags.append(b.allocator, "-mcpu") catch @panic("OOM");
        flags.append(b.allocator, mcpu) catch @panic("OOM");
    }
    return flags.toOwnedSlice(b.allocator) catch @panic("OOM");
}
