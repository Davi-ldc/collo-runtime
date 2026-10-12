//! Zstandard: the one Zig declaration of the part of its API Collo calls,
//! one-shot compression and decompression. The declarations are translated
//! from the pinned tree's `zstd.h` (`runtime/deps/zstd.version`), and the
//! library is compiled from the same tree into every artifact that links
//! this module's users (`runtime/build/codecs.zig`).

const std = @import("std");
const c = @import("zstd_h");

// Zero-length sentinel: only ever returned for an empty slice, and zstd never
// writes to a 0-capacity dst, so the mutable boundary can @constCast it safely.
const empty_byte = [_]u8{0};

pub fn compressBound(src_size: usize) usize {
    return c.ZSTD_compressBound(src_size);
}

/// Compresses all of `src` into `dst` at `level` and returns the compressed
/// length; fails with `error.ZstdFailed` when `dst` is too small.
pub fn compress(
    dst: []u8,
    src: []const u8,
    level: c_int,
) !usize {
    const written = c.ZSTD_compress(
        mutablePointer(dst),
        dst.len,
        constPointer(src),
        src.len,
        level,
    );
    return check(written);
}

/// Decompresses one frame from `src` into `dst` and returns the decompressed
/// length; fails with `error.ZstdFailed` on corrupt input or when `dst` is
/// too small.
pub fn decompress(
    dst: []u8,
    src: []const u8,
) !usize {
    const written = c.ZSTD_decompress(
        mutablePointer(dst),
        dst.len,
        constPointer(src),
        src.len,
    );
    return check(written);
}

fn check(result: usize) !usize {
    if (c.ZSTD_isError(result) == 0)
        return result;
    std.log.warn("zstd failure: {s}", .{std.mem.span(c.ZSTD_getErrorName(result))});
    return error.ZstdFailed;
}

fn mutablePointer(bytes: []u8) [*]u8 {
    if (bytes.len == 0)
        return @constCast(empty_byte[0..].ptr);
    return bytes.ptr;
}

fn constPointer(bytes: []const u8) [*]const u8 {
    if (bytes.len == 0)
        return empty_byte[0..].ptr;
    return bytes.ptr;
}
