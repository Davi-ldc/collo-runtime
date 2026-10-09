//! C/C++ pieces that ride along the Zig build: the JSC bridge, the BoringSSL
//! and ls-hpack shims, and the sanitizer plumbing shared by all of them.
const std = @import("std");
const toolchain_mod = @import("toolchain.zig");

pub const binding_include_paths = [_][]const u8{
    "runtime/src/bindings",
    "runtime/src/bindings/include",
};

pub const webkit_include_suffixes = [_][]const u8{
    "Source",
    "Source/JavaScriptCore",
    "Source/WTF",
    "Source/bmalloc",
};

const binding_sources = [_][]const u8{
    "runtime/src/bindings/jsc/runtime/vm.cpp",
    "runtime/src/bindings/jsc/runtime/global_object.cpp",
    "runtime/src/bindings/jsc/runtime/console_client.cpp",
    "runtime/src/bindings/jsc/runtime/webapi_cache.cpp",
    "runtime/src/bindings/jsc/runtime/values.cpp",
    "runtime/src/bindings/jsc/runtime/promise.cpp",
    "runtime/src/bindings/jsc/runtime/module_loader.cpp",
    "runtime/src/bindings/jsc/runtime/tooling_bytecode.cpp",
    "runtime/src/bindings/jsc/runtime/invoke.cpp",
    "runtime/src/bindings/jsc/zygote/prepare_for_fork.cpp",
    "runtime/src/bindings/jsc/runtime/js_support.cpp",
    "runtime/src/bindings/host_functions/support.cpp",
    "runtime/src/bindings/host_functions/runtime/bridge.cpp",
    "runtime/src/bindings/host_functions/runtime/request_body.cpp",
    "runtime/src/bindings/host_functions/runtime/fetch_body.cpp",
    "runtime/src/bindings/host_functions/runtime/fetch.cpp",
    "runtime/src/bindings/host_functions/runtime/timers.cpp",
    "runtime/src/bindings/host_functions/node/fs.cpp",
    "runtime/src/bindings/host_functions/webapi/encoding/base64.cpp",
    "runtime/src/bindings/host_functions/webapi/encoding/utf8.cpp",
    "runtime/src/bindings/host_functions/webapi/files/blob.cpp",
    "runtime/src/bindings/host_functions/webapi/files/formdata.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/types.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/objects.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/keys.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/jobs.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/key_io/raw.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/key_io/jwk.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/key_io/der.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/key_io/unwrap.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/normalize.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/ops/sha3.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/ops/symmetric.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/ops/asymmetric.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/ops/kdf.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/subtle/digest.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/subtle/key_io.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/subtle/generate.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/subtle/cipher.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/subtle/derive.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/subtle/sign.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/sync/methods.cpp",
    "runtime/src/bindings/host_functions/webapi/crypto/crypto.cpp",
    "runtime/src/bindings/host_functions/webapi/messaging/structured_clone.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/timer_handle.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/report_error.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/navigator.cpp",
    "runtime/src/bindings/host_functions/server/fetch/body_utils.cpp",
    "runtime/src/bindings/host_functions/server/fetch/body_init.cpp",
    "runtime/src/bindings/host_functions/server/fetch/body_consume.cpp",
    "runtime/src/bindings/host_functions/server/fetch/body_abi.cpp",
    "runtime/src/bindings/host_functions/server/fetch/body.cpp",
    "runtime/src/bindings/host_functions/server/fetch/extracted_response.cpp",
    "runtime/src/bindings/host_functions/server/fetch/response_object.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/microtask.cpp",
    "runtime/src/bindings/host_functions/webapi/events/abort.cpp",
    "runtime/src/bindings/host_functions/webapi/dom/dom_exception.cpp",
    "runtime/src/bindings/host_functions/webapi/events/event_types.cpp",
    "runtime/src/bindings/host_functions/webapi/events/event_target.cpp",
    "runtime/src/bindings/host_functions/webapi/messaging/message_channel.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/performance/entry.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/performance/observer.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/performance/performance.cpp",
    "runtime/src/bindings/host_functions/webapi/encoding/text_codec.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/stream_common.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/readable_stream.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/readable_stream_consume.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/readable_stream_objects.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/writable_stream.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/writable_stream_api.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/writable_stream_objects.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/pipe_transform_stream.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/pipe_transform_stream_objects.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/queuing_strategy.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/compression_stream.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/compression_stream_objects.cpp",
    "runtime/src/bindings/host_functions/webapi/streams/streams_install.cpp",
    "runtime/src/bindings/host_functions/server/fetch/headers.cpp",
    "runtime/src/bindings/host_functions/webapi/url/search_params.cpp",
    "runtime/src/bindings/host_functions/webapi/url/url.cpp",
    "runtime/src/bindings/host_functions/webapi/url/pattern/webcore_port/URLPattern.cpp",
    "runtime/src/bindings/host_functions/webapi/url/pattern/webcore_port/URLPatternCanonical.cpp",
    "runtime/src/bindings/host_functions/webapi/url/pattern/webcore_port/URLPatternComponent.cpp",
    "runtime/src/bindings/host_functions/webapi/url/pattern/webcore_port/URLPatternConstructorStringParser.cpp",
    "runtime/src/bindings/host_functions/webapi/url/pattern/webcore_port/URLPatternParser.cpp",
    "runtime/src/bindings/host_functions/webapi/url/pattern/webcore_port/URLPatternTokenizer.cpp",
    "runtime/src/bindings/host_functions/webapi/url/pattern/binding.cpp",
    "runtime/src/bindings/host_functions/server/fetch/request.cpp",
    "runtime/src/bindings/host_functions/server/fetch/response.cpp",
    "runtime/src/bindings/host_functions/server/fetch/fetch.cpp",
    "runtime/src/bindings/host_functions/webapi/platform/timers.cpp",
    "runtime/src/bindings/host_functions/registry.cpp",
};

const binding_cflags = [_][]const u8{
    // Tracks the standard JSC itself is built with, because these translation units include its public
    // headers and those use C++23 in the open: `if consteval` in `wtf/Variant.h`, `std::unexpected` in
    // `wtf/StdLibExtras.h`. Falling behind does not fail on our code — it fails thousands of times
    // inside WTF, which reads as the engine being broken rather than the flag being stale.
    "-std=c++23",
    "-fno-exceptions",
    "-fno-rtti",
    "-DBUILDING_WITH_CMAKE=1",
    "-DHAVE_CONFIG_H=1",
};

/// JSC's unsanitized, AUTO-assert recipe selects these ABI bits by CMake mode.
/// Consumer optimization and ASan instrumentation must not change engine layouts
/// or require debug-only symbols. ASan otherwise enables exception verification
/// in JSC headers even when the linked Release engine does not contain it.
///
/// The bridge's optimization level follows the Zig optimize mode while its ABI
/// follows the engine profile, so a Debug bridge on the Release ABI is a normal
/// dev combination; WTF's Compiler.h refuses NDEBUG without __OPTIMIZE__ unless
/// RELEASE_WITHOUT_OPTIMIZATIONS says that is intended, and nothing else reads it.
pub fn bindingCFlags(
    jsc_cmake_build_type: []const u8,
) error{UnsupportedJscBuildType}![]const []const u8 {
    if (std.mem.eql(u8, jsc_cmake_build_type, "Debug")) {
        return &(binding_cflags ++ [_][]const u8{
            "-UNDEBUG",
            "-DENABLE_EXCEPTION_SCOPE_VERIFICATION=1",
        });
    }
    if (std.mem.eql(u8, jsc_cmake_build_type, "Release")) {
        return &(binding_cflags ++ [_][]const u8{
            "-DNDEBUG",
            "-DENABLE_EXCEPTION_SCOPE_VERIFICATION=0",
            "-DRELEASE_WITHOUT_OPTIMIZATIONS=1",
        });
    }
    return error.UnsupportedJscBuildType;
}

pub const boringssl_shim_cflags = [_][]const u8{
    "-std=c++20",
    "-fno-exceptions",
    "-fno-rtti",
    "-fno-sanitize=undefined",
};

const hpack_cflags = [_][]const u8{
    "-std=c99",
    "-DNDEBUG",
    "-fno-sanitize=undefined",
    "-DLS_HPACK_USE_LARGE_TABLES=1",
    "-DLSHPACK_DEC_HTTP1X_OUTPUT=0",
    "-DLSHPACK_DEC_CALC_HASH=0",
    "-DXXH_HEADER_NAME=\"xxhash.h\"",
};

pub const BindingsSanitizerMode = enum {
    none,
    address_leak,
};

pub const BindingsSanitizer = struct {
    mode: BindingsSanitizerMode = .none,

    pub fn enabled(self: BindingsSanitizer) bool {
        return self.mode != .none;
    }

    pub fn cFlags(self: BindingsSanitizer) []const []const u8 {
        return switch (self.mode) {
            .none => &.{},
            .address_leak => &.{
                "-fsanitize=address,leak",
                "-fno-omit-frame-pointer",
                "-g",
            },
        };
    }

    pub fn linkArgs(self: BindingsSanitizer) []const []const u8 {
        return switch (self.mode) {
            .none => &.{},
            .address_leak => &.{
                "-fsanitize=address,leak",
                "-fno-omit-frame-pointer",
            },
        };
    }

    pub fn runEnv(self: BindingsSanitizer) ?struct { key: []const u8, value: []const u8 } {
        return switch (self.mode) {
            .none => null,
            .address_leak => .{
                .key = "ASAN_OPTIONS",
                .value = "detect_leaks=1:halt_on_error=1:allocator_may_return_null=1",
            },
        };
    }
};

/// Address sanitization of a *Zig* module is a toolchain capability, not a
/// build option: `Build.Module.sanitize_address` exists only on toolchains
/// that carry it, and the pinned stock Zig does not. Asking for the field
/// unguarded makes `build.zig` itself fail to compile, which reports as three
/// unrelated-looking struct errors instead of one toolchain fact — so every
/// request routes through here and the capability is named once.
///
/// The C/C++ half is unaffected either way: `BindingsSanitizer.cFlags`
/// carries `-fsanitize=address,leak` straight to clang, so the bridge stays
/// instrumented on any toolchain. Only the Zig half of a sanitized artifact
/// loses instrumentation when the field is absent.
pub const zig_module_asan_supported = @hasField(std.Build.Module, "sanitize_address");

pub fn sanitizeZigModule(module: *std.Build.Module) void {
    if (comptime zig_module_asan_supported)
        module.sanitize_address = true;
}

pub fn parseBindingsSanitizer(name: []const u8) BindingsSanitizer {
    if (std.mem.eql(u8, name, "none")) {
        return .{ .mode = .none };
    }
    if (std.mem.eql(u8, name, "address") or
        std.mem.eql(u8, name, "address,leak") or
        std.mem.eql(u8, name, "asan") or
        std.mem.eql(u8, name, "asan,lsan"))
    {
        return .{ .mode = .address_leak };
    }
    std.process.fatal(
        "invalid bindings sanitizer '{s}'; expected none or address,leak",
        .{name},
    );
}

pub fn configureBridgeLibrary(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    libc_file: std.Build.LazyPath,
    toolchain: *const toolchain_mod.ToolchainPaths,
    jsc_cmake_build_type: []const u8,
    jsc_build_dir: []const u8,
    webkit_source_dir: []const u8,
    sanitizer: BindingsSanitizer,
) void {
    const cflags = bindingCFlags(jsc_cmake_build_type) catch
        std.process.fatal("unsupported JSC CMake build type '{s}'; expected Debug or Release", .{
            jsc_cmake_build_type,
        });
    artifact.setLibCFile(libc_file);
    artifact.root_module.addCSourceFiles(.{
        .files = &binding_sources,
        .flags = toolchain_mod.cxxFlagsWithTarget(b, toolchain, cflags, sanitizer),
    });
    artifact.root_module.link_libc = true;
    if (sanitizer.enabled())
        sanitizeZigModule(artifact.root_module);

    for (binding_include_paths) |path|
        artifact.addIncludePath(b.path(path));
    artifact.addIncludePath(b.path("runtime/deps/boringssl/include"));
    for (webkit_include_suffixes) |suffix|
        artifact.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ webkit_source_dir, suffix }) });
    for (jscIncludeDirs(b, jsc_build_dir)) |path|
        artifact.addIncludePath(.{ .cwd_relative = path });
    for (toolchain.systemIncludeDirs()) |path|
        artifact.addSystemIncludePath(.{ .cwd_relative = path });
}

pub const jsc_include_suffixes = [_][]const u8{
    "",
    "JavaScriptCore/Headers",
    "JavaScriptCore/Headers/JavaScriptCore",
    "JavaScriptCore/PrivateHeaders",
    "JavaScriptCore/PrivateHeaders/JavaScriptCore",
    "JavaScriptCore/DerivedSources",
    "WTF/Headers",
    "WTF/DerivedSources",
    "bmalloc/Headers",
};

pub fn jscIncludeDirs(
    b: *std.Build,
    jsc_build_dir: []const u8,
) [jsc_include_suffixes.len][]const u8 {
    var paths: [jsc_include_suffixes.len][]const u8 = undefined;
    for (jsc_include_suffixes, 0..) |suffix, index| {
        paths[index] = if (suffix.len == 0)
            jsc_build_dir
        else
            b.pathJoin(&.{ jsc_build_dir, suffix });
    }
    return paths;
}

pub fn configureBindingsTestObject(artifact: *std.Build.Step.Compile, libc_file: std.Build.LazyPath) void {
    artifact.setLibCFile(libc_file);
}

pub fn configureBoringSslShim(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    toolchain: *const toolchain_mod.ToolchainPaths,
    sanitizer: BindingsSanitizer,
) void {
    artifact.root_module.addCSourceFiles(.{
        .files = &.{"runtime/src/bindings/boringssl/shim.cc"},
        .flags = toolchain_mod.cxxFlagsWithTarget(b, toolchain, &boringssl_shim_cflags, sanitizer),
    });
    artifact.addIncludePath(b.path("runtime/deps/boringssl/include"));
    for (toolchain.systemIncludeDirs()) |path|
        artifact.addSystemIncludePath(.{ .cwd_relative = path });
}

pub fn configureBoringSslTestShim(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    toolchain: *const toolchain_mod.ToolchainPaths,
    sanitizer: BindingsSanitizer,
) void {
    artifact.root_module.addCSourceFiles(.{
        .files = &.{"runtime/tests/support/tls/tls_shim.cc"},
        .flags = toolchain_mod.cxxFlagsWithTarget(b, toolchain, &boringssl_shim_cflags, sanitizer),
    });
}

/// `collo_test_tls_shim`: the one Zig declaration of each export of the test
/// TLS shim. A compilation that calls any of them links the shim with
/// `configureBoringSslTestShim`; one that only imports the module pays
/// nothing, since unreferenced declarations are never analyzed.
pub fn tlsTestShimModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/tests/support/tls/shim.zig"),
        .target = target,
        .optimize = optimize,
    });
}

const LsHpackInputMode = enum {
    source_tree,
    patch_files,
};

fn addLsHpackFileInputs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    root_path: []const u8,
    mode: LsHpackInputMode,
) void {
    var root = b.build_root.handle.openDir(root_path, .{ .iterate = true }) catch |err|
        std.process.fatal("cannot enumerate ls-hpack inputs in {s}: {s}", .{
            root_path,
            @errorName(err),
        });
    defer root.close();

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(b.allocator);

    switch (mode) {
        .source_tree => {
            var walker = root.walk(b.allocator) catch |err|
                std.process.fatal("cannot walk ls-hpack source {s}: {s}", .{
                    root_path,
                    @errorName(err),
                });
            defer walker.deinit();

            while (walker.next() catch |err|
                std.process.fatal("cannot walk ls-hpack source {s}: {s}", .{
                    root_path,
                    @errorName(err),
                })) |entry|
            {
                const kind = if (entry.kind == .unknown) blk: {
                    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    if (root.readLink(entry.path, &target_buffer)) |_| {
                        std.process.fatal("ls-hpack cache inputs must be regular files: {s}/{s}", .{
                            root_path,
                            entry.path,
                        });
                    } else |err| switch (err) {
                        error.NotLink => {},
                        else => std.process.fatal("cannot classify ls-hpack input {s}/{s}: {s}", .{
                            root_path,
                            entry.path,
                            @errorName(err),
                        }),
                    }
                    break :blk (root.statFile(entry.path) catch |err|
                        std.process.fatal("cannot stat ls-hpack input {s}/{s}: {s}", .{
                            root_path,
                            entry.path,
                            @errorName(err),
                        })).kind;
                } else entry.kind;
                switch (kind) {
                    .directory => continue,
                    .file => {},
                    .sym_link => std.process.fatal(
                        "ls-hpack cache inputs must be regular files: {s}/{s}",
                        .{ root_path, entry.path },
                    ),
                    else => std.process.fatal(
                        "unsupported ls-hpack cache input kind {s}: {s}/{s}",
                        .{ @tagName(kind), root_path, entry.path },
                    ),
                }
                paths.append(b.allocator, b.pathJoin(&.{ root_path, entry.path })) catch
                    @panic("OOM");
            }
        },
        .patch_files => {
            var iterator = root.iterate();
            while (iterator.next() catch |err|
                std.process.fatal("cannot enumerate ls-hpack patches in {s}: {s}", .{
                    root_path,
                    @errorName(err),
                })) |entry|
            {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".patch"))
                    continue;
                paths.append(b.allocator, b.pathJoin(&.{ root_path, entry.name })) catch
                    @panic("OOM");
            }
        },
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    for (paths.items) |path|
        run.addFileInput(b.path(path));
}

pub fn addPatchedLsHpackSourceStep(b: *std.Build) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "patch-ls-hpack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/build/buildtool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(tool);
    // argv: apply-patches <source_dir> <patch_dir> <out_dir>; the output dir is
    // content-addressed by zig, so a stable tool yields a cache hit.
    run.addArg("apply-patches"); // buildtool subcommand
    run.addDirectoryArg(b.path("runtime/deps/ls-hpack"));
    run.addDirectoryArg(b.path("runtime/patches/ls-hpack"));
    // Run.addDirectoryArg tracks only the directory path, not its contents.
    // Register every copied source and applied patch explicitly so a warm Zig
    // cache cannot silently reuse an obsolete generated dependency tree.
    addLsHpackFileInputs(b, run, "runtime/deps/ls-hpack", .source_tree);
    addLsHpackFileInputs(b, run, "runtime/patches/ls-hpack", .patch_files);
    return run.addOutputDirectoryArg("ls-hpack-patched");
}

pub fn configureHpackShim(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    patched_ls_hpack_source: std.Build.LazyPath,
) void {
    artifact.root_module.addCSourceFiles(.{
        .files = &.{
            "runtime/src/bindings/hpack/shim.c",
            "runtime/deps/ls-hpack/deps/xxhash/xxhash.c",
        },
        .flags = &hpack_cflags,
    });
    artifact.root_module.addCSourceFiles(.{
        .root = patched_ls_hpack_source,
        .files = &.{"lshpack.c"},
        .flags = &hpack_cflags,
    });
    artifact.addIncludePath(patched_ls_hpack_source);
    artifact.addIncludePath(b.path("runtime/deps/ls-hpack/deps/xxhash"));
}

/// BoringSSL static archives for an artifact that links TLS without the JSC
/// bridge (stub-graph tests and benches).
pub fn linkBoringSslArchives(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    boringssl_build_dir: []const u8,
) void {
    artifact.root_module.addObjectFile(b.path(b.pathJoin(&.{ boringssl_build_dir, "libssl.a" })));
    artifact.root_module.addObjectFile(b.path(b.pathJoin(&.{ boringssl_build_dir, "libcrypto.a" })));
    artifact.root_module.linkSystemLibrary("dl", .{});
    artifact.root_module.linkSystemLibrary("pthread", .{});
}
