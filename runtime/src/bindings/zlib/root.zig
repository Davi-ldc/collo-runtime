//! zlib: the one Zig declaration of the part of its API Collo calls, inflate
//! for the fetch body decoders (`egress/core/decompress.zig`). The
//! declarations are translated from the pinned tree's `zlib.h`
//! (`runtime/deps/zlib.version`) with `ZLIB_CONST`, so input is a const
//! pointer, and the library is compiled from the same tree into every
//! artifact that links this module's users (`runtime/build/codecs.zig`).
//! zlib keeps no global state, so a stream belongs to whichever thread uses
//! it.

const c = @import("zlib_h");

/// zlib's `z_stream`, laid out exactly as the compiled library expects.
pub const Stream = c.z_stream;

/// What `inflate` and its siblings return.
pub const ok = c.Z_OK;
pub const stream_end = c.Z_STREAM_END;
pub const need_dict = c.Z_NEED_DICT;
pub const stream_error = c.Z_STREAM_ERROR;
pub const data_error = c.Z_DATA_ERROR;
pub const mem_error = c.Z_MEM_ERROR;
pub const buf_error = c.Z_BUF_ERROR;

/// The flush modes `inflate` takes.
pub const no_flush = c.Z_NO_FLUSH;
pub const finish = c.Z_FINISH;

/// zlib.h's `inflateInit2`: prepares `stream`, whose allocator fields are
/// null so zlib allocates with malloc, to decode with `window_bits`. zlib's
/// state then points back at `stream`, which must not move until
/// `inflateEnd`. Returns `ok`, `mem_error`, or `stream_error` for a bad
/// `window_bits`.
pub fn inflateInit2(stream: *Stream, window_bits: c_int) c_int {
    return c.inflateInit2_(stream, window_bits, c.ZLIB_VERSION, @sizeOf(Stream));
}

/// Decodes from `stream.next_in` into `stream.next_out` as far as both
/// allow; see zlib.h for the return codes.
pub fn inflate(stream: *Stream, flush: c_int) c_int {
    return c.inflate(stream, flush);
}

/// Frees the state `inflateInit2` allocated.
pub fn inflateEnd(stream: *Stream) c_int {
    return c.inflateEnd(stream);
}

/// Restarts `stream` for a new member, keeping its window size.
pub fn inflateReset(stream: *Stream) c_int {
    return c.inflateReset(stream);
}
