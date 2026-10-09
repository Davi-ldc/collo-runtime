//! Narrow zstd C ABI binding used by module-pack artifacts.
const std = @import("std");

// Zero-length sentinel: only ever returned for an empty slice, and zstd never
// writes to a 0-capacity dst, so the mutable boundary can @constCast it safely.
const empty_byte = [_]u8{0};

extern "c" fn ZSTD_compressBound(srcSize: usize) usize;
extern "c" fn ZSTD_compress(
    dst: [*]u8,
    dstCapacity: usize,
    src: [*]const u8,
    srcSize: usize,
    compressionLevel: c_int,
) usize;
extern "c" fn ZSTD_decompress(
    dst: [*]u8,
    dstCapacity: usize,
    src: [*]const u8,
    compressedSize: usize,
) usize;
extern "c" fn ZSTD_isError(code: usize) c_uint;
extern "c" fn ZSTD_getErrorName(code: usize) [*:0]const u8;

pub fn compressBound(src_size: usize) usize {
    return ZSTD_compressBound(src_size);
}

pub fn compress(
    dst: []u8,
    src: []const u8,
    level: c_int,
) !usize {
    const written = ZSTD_compress(
        mutablePointer(dst),
        dst.len,
        constPointer(src),
        src.len,
        level,
    );
    return check(written);
}

pub fn decompress(
    dst: []u8,
    src: []const u8,
) !usize {
    const written = ZSTD_decompress(
        mutablePointer(dst),
        dst.len,
        constPointer(src),
        src.len,
    );
    return check(written);
}

fn check(result: usize) !usize {
    if (ZSTD_isError(result) == 0)
        return result;
    std.log.warn("zstd failure: {s}", .{std.mem.span(ZSTD_getErrorName(result))});
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
