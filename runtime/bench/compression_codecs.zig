//! Compares identity, zstd and Brotli at several levels on three kinds of
//! input: JavaScript and other source text, configuration JSON and random
//! bytes. It
//! prints the encoded size and the mean encode and decode time per corpus
//! case and codec, so the tradeoff is measured before any runtime code picks
//! a codec. The bench imports no runtime module. It loads libzstd and the
//! Brotli libraries with dlopen and fails when any is missing. It reads
//! repository fixtures by relative path, so it runs from the repository
//! root, where the build step sets its working directory. Every case must
//! survive a round trip byte for byte before it is timed. Runs on its main
//! thread and builds ReleaseFast.

const std = @import("std");
const bench_metadata = @import("metadata.zig");

const workload_array_ops_js = @embedFile("workload_array_ops_js");
const workload_chacha_js = @embedFile("workload_chacha_js");
const workload_growing_cache_js = @embedFile("workload_growing_cache_js");
const workload_hmac_sha256_js = @embedFile("workload_hmac_sha256_js");
const workload_json_roundtrip_js = @embedFile("workload_json_roundtrip_js");
const workload_json_scan_js = @embedFile("workload_json_scan_js");
const workload_many_functions_js = @embedFile("workload_many_functions_js");
const workload_regex_router_js = @embedFile("workload_regex_router_js");
const workload_shape_churn_js = @embedFile("workload_shape_churn_js");
const workload_ssr_js = @embedFile("workload_ssr_js");

const workload_js =
    workload_array_ops_js ++ "\n" ++
    workload_chacha_js ++ "\n" ++
    workload_growing_cache_js ++ "\n" ++
    workload_hmac_sha256_js ++ "\n" ++
    workload_json_roundtrip_js ++ "\n" ++
    workload_json_scan_js ++ "\n" ++
    workload_many_functions_js ++ "\n" ++
    workload_regex_router_js ++ "\n" ++
    workload_shape_churn_js ++ "\n" ++
    workload_ssr_js;

const default_rounds: usize = 3;
const min_case_bytes: usize = 1;

const Surface = enum {
    static_file,
    metadata,
    adversarial,
};

const Codec = enum {
    identity,
    zstd,
    br,
};

const CodecSpec = struct {
    codec: Codec,
    level: u8,
};

const codecs = [_]CodecSpec{
    .{ .codec = .identity, .level = 0 },
    .{ .codec = .zstd, .level = 1 },
    .{ .codec = .zstd, .level = 3 },
    .{ .codec = .zstd, .level = 7 },
    .{ .codec = .zstd, .level = 10 },
    .{ .codec = .zstd, .level = 12 },
    .{ .codec = .zstd, .level = 15 },
    .{ .codec = .zstd, .level = 19 },
    .{ .codec = .zstd, .level = 22 },
    .{ .codec = .br, .level = 5 },
    .{ .codec = .br, .level = 9 },
    .{ .codec = .br, .level = 11 },
};

const CorpusCase = struct {
    surface: Surface,
    name: []const u8,
    bytes: []u8,

    fn deinit(self: *CorpusCase, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const DynamicLib = struct {
    handle: *anyopaque,

    fn openAny(names: []const [:0]const u8) !DynamicLib {
        for (names) |name| {
            if (std.c.dlopen(name.ptr, .{ .LAZY = true })) |handle| {
                return .{ .handle = handle };
            }
        }
        return error.FileNotFound;
    }

    fn close(self: *DynamicLib) void {
        _ = std.c.dlclose(self.handle);
        self.* = undefined;
    }

    fn lookup(self: *DynamicLib, comptime T: type, name: [:0]const u8) !T {
        const symbol = @call(.never_tail, std.c.dlsym, .{ self.handle, name.ptr }) orelse {
            return error.MissingSymbol;
        };
        return @as(T, @ptrCast(@alignCast(symbol)));
    }
};

const BrotliEncoderMaxCompressedSizeFn = *const fn (usize) callconv(.c) usize;
const BrotliEncoderCompressFn = *const fn (
    c_int,
    c_int,
    c_int,
    usize,
    [*]const u8,
    *usize,
    [*]u8,
) callconv(.c) c_int;
const BrotliDecoderDecompressFn = *const fn (
    usize,
    [*]const u8,
    *usize,
    [*]u8,
) callconv(.c) c_int;
const ZstdCompressBoundFn = *const fn (usize) callconv(.c) usize;
const ZstdCompressFn = *const fn (
    [*]u8,
    usize,
    [*]const u8,
    usize,
    c_int,
) callconv(.c) usize;
const ZstdDecompressFn = *const fn (
    [*]u8,
    usize,
    [*]const u8,
    usize,
) callconv(.c) usize;
const ZstdIsErrorFn = *const fn (usize) callconv(.c) c_uint;
const ZstdGetErrorNameFn = *const fn (usize) callconv(.c) [*:0]const u8;

const CodecLibs = struct {
    brotli_encoder: DynamicLib,
    brotli_decoder: DynamicLib,
    zstd: DynamicLib,
    brotli_max_compressed_size: BrotliEncoderMaxCompressedSizeFn,
    brotli_compress: BrotliEncoderCompressFn,
    brotli_decompress: BrotliDecoderDecompressFn,
    zstd_compress_bound: ZstdCompressBoundFn,
    zstd_compress: ZstdCompressFn,
    zstd_decompress: ZstdDecompressFn,
    zstd_is_error: ZstdIsErrorFn,
    zstd_get_error_name: ZstdGetErrorNameFn,

    fn init() !CodecLibs {
        var brotli_encoder = try DynamicLib.openAny(&.{ "libbrotlienc.so.1", "libbrotlienc.so" });
        errdefer brotli_encoder.close();
        var brotli_decoder = try DynamicLib.openAny(&.{ "libbrotlidec.so.1", "libbrotlidec.so" });
        errdefer brotli_decoder.close();
        var zstd = try DynamicLib.openAny(&.{ "libzstd.so.1", "libzstd.so" });
        errdefer zstd.close();

        return .{
            .brotli_encoder = brotli_encoder,
            .brotli_decoder = brotli_decoder,
            .zstd = zstd,
            .brotli_max_compressed_size = try brotli_encoder.lookup(
                BrotliEncoderMaxCompressedSizeFn,
                "BrotliEncoderMaxCompressedSize",
            ),
            .brotli_compress = try brotli_encoder.lookup(
                BrotliEncoderCompressFn,
                "BrotliEncoderCompress",
            ),
            .brotli_decompress = try brotli_decoder.lookup(
                BrotliDecoderDecompressFn,
                "BrotliDecoderDecompress",
            ),
            .zstd_compress_bound = try zstd.lookup(ZstdCompressBoundFn, "ZSTD_compressBound"),
            .zstd_compress = try zstd.lookup(ZstdCompressFn, "ZSTD_compress"),
            .zstd_decompress = try zstd.lookup(ZstdDecompressFn, "ZSTD_decompress"),
            .zstd_is_error = try zstd.lookup(ZstdIsErrorFn, "ZSTD_isError"),
            .zstd_get_error_name = try zstd.lookup(ZstdGetErrorNameFn, "ZSTD_getErrorName"),
        };
    }

    fn deinit(self: *CodecLibs) void {
        self.zstd.close();
        self.brotli_decoder.close();
        self.brotli_encoder.close();
        self.* = undefined;
    }

    fn maxCompressedSize(self: *const CodecLibs, codec: Codec, raw_len: usize) usize {
        return switch (codec) {
            .identity => raw_len,
            .zstd => self.zstd_compress_bound(raw_len),
            .br => self.brotli_max_compressed_size(raw_len),
        };
    }

    fn compressInto(
        self: *const CodecLibs,
        spec: CodecSpec,
        input: []const u8,
        output: []u8,
    ) !usize {
        std.debug.assert(input.len >= min_case_bytes);
        switch (spec.codec) {
            .identity => {
                @memcpy(output[0..input.len], input);
                return input.len;
            },
            .zstd => {
                const written = self.zstd_compress(
                    output.ptr,
                    output.len,
                    input.ptr,
                    input.len,
                    spec.level,
                );
                try self.checkZstd(written);
                return written;
            },
            .br => {
                var out_len = output.len;
                const ok = self.brotli_compress(
                    spec.level,
                    22,
                    1,
                    input.len,
                    input.ptr,
                    &out_len,
                    output.ptr,
                );
                if (ok == 0) {
                    return error.BrotliCompressFailed;
                }
                return out_len;
            },
        }
    }

    fn decompressInto(
        self: *const CodecLibs,
        spec: CodecSpec,
        compressed: []const u8,
        output: []u8,
    ) !usize {
        switch (spec.codec) {
            .identity => {
                @memcpy(output[0..compressed.len], compressed);
                return compressed.len;
            },
            .zstd => {
                const written = self.zstd_decompress(
                    output.ptr,
                    output.len,
                    compressed.ptr,
                    compressed.len,
                );
                try self.checkZstd(written);
                return written;
            },
            .br => {
                var out_len = output.len;
                const result = self.brotli_decompress(
                    compressed.len,
                    compressed.ptr,
                    &out_len,
                    output.ptr,
                );
                if (result != 1) {
                    return error.BrotliDecompressFailed;
                }
                return out_len;
            },
        }
    }

    fn checkZstd(self: *const CodecLibs, result: usize) !void {
        if (self.zstd_is_error(result) == 0) {
            return;
        }
        std.log.err("zstd failure: {s}", .{self.zstd_get_error_name(result)});
        return error.ZstdFailed;
    }
};

const Measurement = struct {
    encoded_bytes: usize,
    encode_ns_avg: u64,
    decode_ns_avg: u64,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    try bench_metadata.print(allocator, "compression_codecs");

    var libs = CodecLibs.init() catch |err| {
        std.log.err("compression codec libraries are required for this benchmark: {s}", .{@errorName(err)});
        return err;
    };
    defer libs.deinit();

    const rounds = try envUsize(allocator, "COLLO_BENCH_COMPRESSION_ROUNDS", default_rounds);
    var corpus = std.array_list.Aligned(CorpusCase, null).empty;
    defer {
        for (corpus.items) |*entry| {
            entry.deinit(allocator);
        }
        corpus.deinit(allocator);
    }
    try buildCorpus(allocator, &corpus);

    for (corpus.items) |entry| {
        for (codecs) |codec| {
            const measurement = try measureCodec(allocator, &libs, entry.bytes, codec, rounds);
            printMeasurement(entry, codec, measurement, rounds);
        }
    }
}

fn buildCorpus(allocator: std.mem.Allocator, corpus: *std.array_list.Aligned(CorpusCase, null)) !void {
    try appendRepoFile(
        allocator,
        corpus,
        .static_file,
        "fixture_bundled_route_todos",
        "runtime/tests/integration/fixtures/local_e2e/api/todos.js",
        16 * 1024 * 1024,
    );
    try appendRepoConcat(
        allocator,
        corpus,
        .static_file,
        "fixture_route_js_concat",
        &.{
            "runtime/tests/integration/fixtures/local_e2e/api/fetch_gzip.js",
            "runtime/tests/integration/fixtures/local_e2e/api/large_response.js",
            "runtime/tests/integration/fixtures/local_e2e/api/echo.js",
            "runtime/tests/integration/fixtures/local_e2e/api/hello.js",
            "runtime/tests/integration/fixtures/local_e2e/api/hang_before.js",
        },
    );
    try appendBytes(allocator, corpus, .static_file, "bench_workloads_js_concat", workload_js);
    try appendRepeated(allocator, corpus, .static_file, "synthetic_route_bundle_256k", workload_js, 256 * 1024);
    try appendRepoConcat(
        allocator,
        corpus,
        .static_file,
        "repo_text_code_large",
        &.{
            "runtime/src/bindings/host_functions/webapi/encoding/text_codec.cpp",
            "runtime/src/common/tests/ipc.zig",
            "runtime/src/bindings/host_functions/webapi/crypto/key_io/raw.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/key_io/jwk.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/key_io/der.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/key_io/unwrap.cpp",
            "runtime/src/server/tests/http2/connection.zig",
            "runtime/src/bindings/host_functions/webapi/streams/readable_stream.cpp",
            "runtime/tests/webapi/crypto/crypto.test.js",
            "runtime/src/bindings/host_functions/webapi/crypto/subtle/digest.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/subtle/key_io.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/subtle/generate.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/subtle/cipher.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/subtle/derive.cpp",
            "runtime/src/bindings/host_functions/webapi/crypto/subtle/sign.cpp",
            "runtime/src/bindings/host_functions/webapi/files/formdata.cpp",
            "runtime/src/egress/client/engine/h2_engine.zig",
            "runtime/tests/webapi/url_pattern/urlpatterntestdata.json",
        },
    );
    try appendRepoFile(
        allocator,
        corpus,
        .metadata,
        "fixture_collo_json",
        "runtime/tests/integration/fixtures/local_e2e/collo.json",
        512 * 1024,
    );
    try appendRandom(allocator, corpus, .adversarial, "random_256k", 256 * 1024);
}

fn appendBytes(
    allocator: std.mem.Allocator,
    corpus: *std.array_list.Aligned(CorpusCase, null),
    surface: Surface,
    name: []const u8,
    bytes: []const u8,
) !void {
    if (bytes.len < min_case_bytes) {
        return;
    }
    try corpus.append(allocator, .{
        .surface = surface,
        .name = name,
        .bytes = try allocator.dupe(u8, bytes),
    });
}

fn appendRepeated(
    allocator: std.mem.Allocator,
    corpus: *std.array_list.Aligned(CorpusCase, null),
    surface: Surface,
    name: []const u8,
    seed: []const u8,
    target_len: usize,
) !void {
    std.debug.assert(seed.len != 0);
    std.debug.assert(target_len >= min_case_bytes);
    const bytes = try allocator.alloc(u8, target_len);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const len = @min(seed.len, bytes.len - offset);
        @memcpy(bytes[offset..][0..len], seed[0..len]);
        offset += len;
    }
    try corpus.append(allocator, .{
        .surface = surface,
        .name = name,
        .bytes = bytes,
    });
}

fn appendRandom(
    allocator: std.mem.Allocator,
    corpus: *std.array_list.Aligned(CorpusCase, null),
    surface: Surface,
    name: []const u8,
    len: usize,
) !void {
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    var random = std.Random.DefaultPrng.init(0xC0110);
    random.random().bytes(bytes);
    try corpus.append(allocator, .{
        .surface = surface,
        .name = name,
        .bytes = bytes,
    });
}

fn appendRepoFile(
    allocator: std.mem.Allocator,
    corpus: *std.array_list.Aligned(CorpusCase, null),
    surface: Surface,
    name: []const u8,
    path: []const u8,
    limit: usize,
) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, limit);
    errdefer allocator.free(bytes);
    if (bytes.len < min_case_bytes) {
        return error.EmptyCorpusFile;
    }
    try corpus.append(allocator, .{
        .surface = surface,
        .name = name,
        .bytes = bytes,
    });
}

fn appendRepoConcat(
    allocator: std.mem.Allocator,
    corpus: *std.array_list.Aligned(CorpusCase, null),
    surface: Surface,
    name: []const u8,
    paths: []const []const u8,
) !void {
    std.debug.assert(paths.len != 0);

    var base: std.Io.Writer.Allocating = .init(allocator);
    errdefer base.deinit();
    for (paths) |path| {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
        defer allocator.free(bytes);
        try base.writer.print("\n// file: {s}\n", .{path});
        try base.writer.writeAll(bytes);
    }

    const source = base.written();
    if (source.len == 0) {
        return error.EmptyCorpusFile;
    }
    try corpus.append(allocator, .{
        .surface = surface,
        .name = name,
        .bytes = try base.toOwnedSlice(),
    });
}

fn measureCodec(
    allocator: std.mem.Allocator,
    libs: *const CodecLibs,
    input: []const u8,
    spec: CodecSpec,
    rounds: usize,
) !Measurement {
    std.debug.assert(rounds > 0);

    const compressed_capacity = libs.maxCompressedSize(spec.codec, input.len);
    const compressed = try allocator.alloc(u8, compressed_capacity);
    defer allocator.free(compressed);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);

    const encoded_bytes = try libs.compressInto(spec, input, compressed);
    const decoded_bytes = try libs.decompressInto(spec, compressed[0..encoded_bytes], restored);
    if (decoded_bytes != input.len) {
        return error.CodecRoundTripMismatch;
    }
    if (!std.mem.eql(u8, input, restored[0..decoded_bytes])) {
        return error.CodecRoundTripMismatch;
    }

    if (spec.codec == .identity) {
        return .{
            .encoded_bytes = encoded_bytes,
            .encode_ns_avg = 0,
            .decode_ns_avg = 0,
        };
    }

    const iterations = iterationsFor(input.len, spec);
    var encode_total_ns: u128 = 0;
    var decode_total_ns: u128 = 0;

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const encode_start = try monotonicNowNs();
        var iteration: usize = 0;
        while (iteration < iterations) : (iteration += 1) {
            const written = try libs.compressInto(spec, input, compressed);
            std.debug.assert(written == encoded_bytes);
        }
        encode_total_ns += try elapsedSince(encode_start);

        const decode_start = try monotonicNowNs();
        iteration = 0;
        while (iteration < iterations) : (iteration += 1) {
            const written = try libs.decompressInto(spec, compressed[0..encoded_bytes], restored);
            std.debug.assert(written == input.len);
        }
        decode_total_ns += try elapsedSince(decode_start);
    }

    const divisor: u128 = @as(u128, rounds) * @as(u128, iterations);
    return .{
        .encoded_bytes = encoded_bytes,
        .encode_ns_avg = @intCast(encode_total_ns / divisor),
        .decode_ns_avg = @intCast(decode_total_ns / divisor),
    };
}

fn iterationsFor(input_len: usize, spec: CodecSpec) usize {
    std.debug.assert(input_len >= min_case_bytes);
    if (spec.codec == .br and spec.level >= 11) {
        return @max(@as(usize, 1), @min(@as(usize, 10), 512 * 1024 / input_len));
    }
    if (spec.codec == .br and spec.level >= 9) {
        return @max(@as(usize, 1), @min(@as(usize, 30), 1024 * 1024 / input_len));
    }
    return @max(@as(usize, 3), @min(@as(usize, 120), 4 * 1024 * 1024 / input_len));
}

fn printMeasurement(entry: CorpusCase, spec: CodecSpec, measurement: Measurement, rounds: usize) void {
    const ratio_scaled = if (entry.bytes.len == 0)
        @as(u64, 0)
    else
        (@as(u64, @intCast(measurement.encoded_bytes)) * 1_000_000) /
            @as(u64, @intCast(entry.bytes.len));

    std.debug.print("{{\"bench\":\"compression_codecs\"", .{});
    printJsonString("event", "measurement");
    printJsonString("surface", @tagName(entry.surface));
    printJsonString("corpus", entry.name);
    printJsonString("codec", @tagName(spec.codec));
    std.debug.print(
        ",\"level\":{d},\"rounds\":{d},\"raw_bytes\":{d},\"encoded_bytes\":{d}," ++
            "\"ratio_scaled_1e6\":{d},\"encode_ns_avg\":{d},\"decode_ns_avg\":{d}}}\n",
        .{
            spec.level,
            rounds,
            entry.bytes.len,
            measurement.encoded_bytes,
            ratio_scaled,
            measurement.encode_ns_avg,
            measurement.decode_ns_avg,
        },
    );
}

fn envUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize) !usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => |other| return other,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        return error.InvalidEnvironmentValue;
    }
    const value = try std.fmt.parseUnsigned(usize, trimmed, 10);
    if (value == 0) {
        return error.InvalidEnvironmentValue;
    }
    return value;
}

fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn elapsedSince(start_ns: u64) !u64 {
    const now_ns = try monotonicNowNs();
    if (now_ns < start_ns) {
        return error.ClockWentBackwards;
    }
    return now_ns - start_ns;
}

fn printJsonString(name: []const u8, value: []const u8) void {
    std.debug.print(",\"{s}\":\"", .{name});
    for (value) |byte| switch (byte) {
        '"' => std.debug.print("\\\"", .{}),
        '\\' => std.debug.print("\\\\", .{}),
        '\n' => std.debug.print("\\n", .{}),
        '\r' => std.debug.print("\\r", .{}),
        '\t' => std.debug.print("\\t", .{}),
        else => if (byte < 0x20)
            std.debug.print("\\u{X:0>4}", .{byte})
        else
            std.debug.print("{c}", .{byte}),
    };
    std.debug.print("\"", .{});
}
