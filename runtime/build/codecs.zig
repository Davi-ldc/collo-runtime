//! The compression codecs Collo runs, zlib, brotli and zstd, compiled from
//! their pinned trees (`runtime/deps/<codec>.version`) into one static
//! library each per target, and their public headers as Zig modules through
//! translate-C. Nothing is taken from the machine: the egress decoders, the
//! CompressionStream bridge and the codec bench all run this code.
//!
//! The libraries build in ReleaseFast with C sanitizers off whatever the
//! runtime's `-Doptimize`, because they are pinned input like the engine,
//! whose profile is independent of it too, and Debug C mode traps on
//! upstream code the production build never traps on. Each compilation
//! waits on the verification that the trees are pristine at their pins
//! (`deps.Native.verifyCompiledTrees`), since it reads them in place.
//!
//! The binding modules (`bindings/<codec>/root.zig`) carry no library, so
//! the artifact that links names the archives: an executable Zig links takes
//! them through `linkInto`, and a link link.zig drives through
//! `addToCxxLink`. A static archive contributes only the members something
//! references, so an artifact that calls no codec gains nothing from them.

const std = @import("std");

pub const Codecs = struct {
    zlib: Built,
    brotli: Built,
    zstd: Built,
};

pub const Built = struct {
    library: *std.Build.Step.Compile,
    /// The public headers' declarations, translated to Zig. Only the codec's
    /// binding module imports it.
    header_module: *std.Build.Module,
    /// The translation that produces `header_module`, for a step that checks
    /// it without compiling a consumer.
    translation: *std.Build.Step,
    /// A directory holding the public headers and nothing else, for C and
    /// C++ that includes them.
    include_dir: std.Build.LazyPath,
};

/// Every consumer of `zlib.h` declares `next_in` const, as the C++ bridge
/// and the Zig binding both hand zlib read-only input. The macro changes no
/// layout and no symbol, so the library itself compiles without it.
pub const zlib_consumer_macro = "ZLIB_CONST";

const zlib_tree = "runtime/deps/zlib";
const brotli_tree = "runtime/deps/brotli";
const zstd_tree = "runtime/deps/zstd";

/// zlib's inflate and deflate; the gz* file API is left out because nothing
/// calls it.
const zlib_sources = [_][]const u8{
    "adler32.c", "compress.c", "crc32.c", "deflate.c", "infback.c", "inffast.c",
    "inflate.c", "inftrees.c", "trees.c", "uncompr.c", "zutil.c",
};
/// What zlib's own configure defines on Linux, with internal symbols hidden.
const zlib_flags = [_][]const u8{ "-DHAVE_UNISTD_H=1", "-DHAVE_STDARG_H=1", "-DHAVE_HIDDEN" };

/// Every C source upstream's CMake globs under `c/common`, `c/dec` and
/// `c/enc`, listed so a pin bump that adds one fails the link instead of
/// changing the code silently.
const brotli_sources = [_][]const u8{
    "c/common/constants.c",         "c/common/context.c",
    "c/common/dictionary.c",        "c/common/platform.c",
    "c/common/shared_dictionary.c", "c/common/transform.c",
    "c/dec/bit_reader.c",           "c/dec/decode.c",
    "c/dec/huffman.c",              "c/dec/prefix.c",
    "c/dec/state.c",                "c/dec/static_init.c",
    "c/enc/backward_references.c",  "c/enc/backward_references_hq.c",
    "c/enc/bit_cost.c",             "c/enc/block_splitter.c",
    "c/enc/brotli_bit_stream.c",    "c/enc/cluster.c",
    "c/enc/command.c",              "c/enc/compound_dictionary.c",
    "c/enc/compress_fragment.c",    "c/enc/compress_fragment_two_pass.c",
    "c/enc/dictionary_hash.c",      "c/enc/encode.c",
    "c/enc/encoder_dict.c",         "c/enc/entropy_encode.c",
    "c/enc/fast_log.c",             "c/enc/histogram.c",
    "c/enc/literal_cost.c",         "c/enc/memory.c",
    "c/enc/metablock.c",            "c/enc/static_dict.c",
    "c/enc/static_dict_lut.c",      "c/enc/static_init.c",
    "c/enc/utf8_util.c",
};
/// glibc's libm has log2, which upstream's CMake detects; the static tables
/// stay compile-time data (`BROTLI_STATIC_INIT` defaults to none), so no
/// process writes them at start-up.
const brotli_flags = [_][]const u8{"-DBROTLI_HAVE_LOG2=1"};

/// `lib/common`, `lib/compress` and `lib/decompress`, without the legacy
/// formats, the dictionary builder or multithreading.
const zstd_sources = [_][]const u8{
    "lib/common/debug.c",                      "lib/common/entropy_common.c",
    "lib/common/error_private.c",              "lib/common/fse_decompress.c",
    "lib/common/pool.c",                       "lib/common/threading.c",
    "lib/common/xxhash.c",                     "lib/common/zstd_common.c",
    "lib/compress/fse_compress.c",             "lib/compress/hist.c",
    "lib/compress/huf_compress.c",             "lib/compress/zstd_compress.c",
    "lib/compress/zstd_compress_literals.c",   "lib/compress/zstd_compress_sequences.c",
    "lib/compress/zstd_compress_superblock.c", "lib/compress/zstd_double_fast.c",
    "lib/compress/zstd_fast.c",                "lib/compress/zstd_lazy.c",
    "lib/compress/zstd_ldm.c",                 "lib/compress/zstd_opt.c",
    "lib/compress/zstd_preSplit.c",            "lib/compress/zstdmt_compress.c",
    "lib/decompress/huf_decompress.c",         "lib/decompress/zstd_ddict.c",
    "lib/decompress/zstd_decompress.c",        "lib/decompress/zstd_decompress_block.c",
};
/// The x86_64 Huffman decoder loop, which the C code calls only on x86_64.
const zstd_x86_64_sources = [_][]const u8{"lib/decompress/huf_decompress_amd64.S"};
/// Upstream's own library defines: xxhash under zstd's prefix, so it never
/// collides with another copy in the binary, no legacy formats and no debug
/// tracing.
const zstd_flags = [_][]const u8{ "-DXXH_NAMESPACE=ZSTD_", "-DZSTD_LEGACY_SUPPORT=0", "-DDEBUGLEVEL=0" };

/// The three codecs for `target`. `verify` is the step that proves the trees
/// pristine at their pins.
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, verify: *std.Build.Step) Codecs {
    const zlib_include = publicHeaders(b, verify, "zlib-include", zlib_tree, &.{ "zlib.h", "zconf.h" });
    const zstd_include = publicHeaders(b, verify, "zstd-include", zstd_tree, &.{ "lib/zstd.h", "lib/zstd_errors.h" });
    // Brotli keeps its public headers apart already; the copy gives every
    // compilation that includes them an edge to the verification.
    const brotli_headers = b.addNamedWriteFiles("brotli-include");
    brotli_headers.step.dependOn(verify);
    const brotli_include = brotli_headers.addCopyDirectory(b.path(brotli_tree ++ "/c/include"), "include", .{});

    const zstd_all_sources: []const []const u8 = if (target.result.cpu.arch == .x86_64)
        &(zstd_sources ++ zstd_x86_64_sources)
    else
        &zstd_sources;

    // Brotli's encoder and decoder headers share types, so one translation
    // of a root that includes both keeps those types identical.
    const brotli_root = b.addWriteFiles();
    brotli_root.step.dependOn(verify);
    const brotli_header = brotli_root.add("brotli.h",
        \\#include <brotli/decode.h>
        \\#include <brotli/encode.h>
        \\
    );

    const zlib_h = translate(b, target, verify, zlib_include.path(b, "zlib.h"), zlib_include, &.{zlib_consumer_macro});
    const brotli_h = translate(b, target, verify, brotli_header, brotli_include, &.{});
    const zstd_h = translate(b, target, verify, zstd_include.path(b, "zstd.h"), zstd_include, &.{});

    return .{
        .zlib = .{
            .library = library(b, target, verify, .{
                .name = "collo_zlib",
                .root = zlib_tree,
                .sources = &zlib_sources,
                .flags = &zlib_flags,
                .include = b.path(zlib_tree),
            }),
            .header_module = zlib_h.createModule(),
            .translation = &zlib_h.step,
            .include_dir = zlib_include,
        },
        .brotli = .{
            .library = library(b, target, verify, .{
                .name = "collo_brotli",
                .root = brotli_tree,
                .sources = &brotli_sources,
                .flags = &brotli_flags,
                .include = brotli_include,
            }),
            .header_module = brotli_h.createModule(),
            .translation = &brotli_h.step,
            .include_dir = brotli_include,
        },
        .zstd = .{
            .library = library(b, target, verify, .{
                .name = "collo_zstd",
                .root = zstd_tree,
                .sources = zstd_all_sources,
                .flags = &zstd_flags,
                .include = b.path(zstd_tree ++ "/lib"),
            }),
            .header_module = zstd_h.createModule(),
            .translation = &zstd_h.step,
            .include_dir = zstd_include,
        },
    };
}

/// Names the three archives in a link that link.zig drives.
pub fn addToCxxLink(link: *std.Build.Step.Run, codecs: *const Codecs) void {
    link.addArtifactArg(codecs.zlib.library);
    link.addArtifactArg(codecs.brotli.library);
    link.addArtifactArg(codecs.zstd.library);
}

/// Links the three libraries into `compile`, an executable or test Zig
/// links itself.
pub fn linkInto(compile: *std.Build.Step.Compile, codecs: *const Codecs) void {
    compile.root_module.linkLibrary(codecs.zlib.library);
    compile.root_module.linkLibrary(codecs.brotli.library);
    compile.root_module.linkLibrary(codecs.zstd.library);
}

/// Lets `compile` include the public headers of zlib and brotli, as the
/// CompressionStream bridge does, with the consumer macro zlib's binding uses.
pub fn addBridgeIncludes(compile: *std.Build.Step.Compile, codecs: *const Codecs) void {
    compile.root_module.addIncludePath(codecs.zlib.include_dir);
    compile.root_module.addIncludePath(codecs.brotli.include_dir);
    compile.root_module.addCMacro(zlib_consumer_macro, "1");
}

const LibrarySpec = struct {
    name: []const u8,
    root: []const u8,
    sources: []const []const u8,
    flags: []const []const u8,
    include: std.Build.LazyPath,
};

fn library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    verify: *std.Build.Step,
    spec: LibrarySpec,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .sanitize_c = .off,
        .pic = true,
    });
    module.addCSourceFiles(.{
        .root = b.path(spec.root),
        .files = spec.sources,
        .flags = spec.flags,
    });
    module.addIncludePath(spec.include);
    const compile = b.addLibrary(.{
        .name = spec.name,
        .linkage = .static,
        .root_module = module,
    });
    // Every executable brings its own runtime helpers (link.zig's carrier, or
    // Zig's own link), so a copy inside a codec archive could only collide.
    compile.bundle_compiler_rt = false;
    compile.bundle_ubsan_rt = false;
    compile.step.dependOn(verify);
    return compile;
}

/// A directory of copies of `headers`, files of `tree`, under their base
/// names, so an include path exposes them and none of the tree's private
/// headers (zlib's `inflate.h` and `trees.h` share a directory with
/// `zlib.h`).
fn publicHeaders(
    b: *std.Build,
    verify: *std.Build.Step,
    name: []const u8,
    tree: []const u8,
    headers: []const []const u8,
) std.Build.LazyPath {
    const files = b.addNamedWriteFiles(name);
    files.step.dependOn(verify);
    for (headers) |header|
        _ = files.addCopyFile(b.path(b.pathJoin(&.{ tree, header })), std.fs.path.basename(header));
    return files.getDirectory();
}

/// The declarations `root_header` reaches through `include`, translated for
/// `target`, with `macros` defined first.
fn translate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    verify: *std.Build.Step,
    root_header: std.Build.LazyPath,
    include: std.Build.LazyPath,
    macros: []const []const u8,
) *std.Build.Step.TranslateC {
    const translation = b.addTranslateC(.{
        .root_source_file = root_header,
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    translation.addIncludePath(include);
    for (macros) |macro|
        translation.defineCMacro(macro, "1");
    translation.step.dependOn(verify);
    return translation;
}

/// Compiles the three libraries and translates their headers, without a
/// consumer: what `zig build codecs` runs.
pub fn addCheckTo(step: *std.Build.Step, codecs: *const Codecs) void {
    for ([_]Built{ codecs.zlib, codecs.brotli, codecs.zstd }) |built| {
        step.dependOn(&built.library.step);
        step.dependOn(built.translation);
    }
}
