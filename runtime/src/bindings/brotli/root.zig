//! Brotli: the one Zig declaration of the part of its API Collo calls, the
//! streaming decoder for fetch bodies (`egress/core/decompress.zig`) and the
//! one-shot encoder and decoder the codec bench measures. The declarations
//! are translated from the pinned tree's `brotli/decode.h` and
//! `brotli/encode.h` (`runtime/deps/brotli.version`), and the library is
//! compiled from the same tree into every artifact that links this module's
//! users (`runtime/build/codecs.zig`). Brotli keeps no global mutable state,
//! so a decoder belongs to whichever thread uses it.

const c = @import("brotli_h");

pub const DecoderState = c.BrotliDecoderState;

/// `BrotliDecoderResult`. Non-exhaustive, so a value a later version adds
/// stays representable instead of being undefined behavior.
pub const DecoderResult = enum(c_uint) {
    failure = c.BROTLI_DECODER_RESULT_ERROR,
    success = c.BROTLI_DECODER_RESULT_SUCCESS,
    needs_more_input = c.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT,
    needs_more_output = c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT,
    _,
};

/// The encoder's hint about its input (`BrotliEncoderMode`).
pub const EncoderMode = enum(c_uint) {
    generic = c.BROTLI_MODE_GENERIC,
    text = c.BROTLI_MODE_TEXT,
    font = c.BROTLI_MODE_FONT,
};

pub const quality_max: c_int = c.BROTLI_MAX_QUALITY;
pub const default_window_bits: c_int = c.BROTLI_DEFAULT_WINDOW;

/// A streaming decoder that allocates with malloc and free, or null when
/// that allocation fails. The caller destroys it with `decoderDestroy`.
pub fn decoderCreate() ?*DecoderState {
    return c.BrotliDecoderCreateInstance(null, null, null);
}

pub fn decoderDestroy(state: *DecoderState) void {
    c.BrotliDecoderDestroyInstance(state);
}

/// Decodes from `next_in` into `next_out`, advancing both pointers and
/// lowering both counts by what it consumed and produced. `next_in` may be
/// null while `available_in` is 0.
pub fn decompressStream(
    state: *DecoderState,
    available_in: *usize,
    next_in: *[*c]const u8,
    available_out: *usize,
    next_out: *[*c]u8,
) DecoderResult {
    return @enumFromInt(c.BrotliDecoderDecompressStream(state, available_in, next_in, available_out, next_out, null));
}

/// The largest output `compress` can produce for `input_len` bytes, or 0
/// when that size does not fit a `usize`.
pub fn maxCompressedSize(input_len: usize) usize {
    return c.BrotliEncoderMaxCompressedSize(input_len);
}

/// Compresses all of `input` into `output` and returns the encoded length.
/// Fails with `error.BrotliFailed` when `output` is too small or `quality`
/// or `window_bits` is out of range.
pub fn compress(quality: c_int, window_bits: c_int, mode: EncoderMode, input: []const u8, output: []u8) !usize {
    var encoded_len: usize = output.len;
    const succeeded = c.BrotliEncoderCompress(
        quality,
        window_bits,
        @intFromEnum(mode),
        input.len,
        input.ptr,
        &encoded_len,
        output.ptr,
    );
    if (succeeded == c.BROTLI_FALSE)
        return error.BrotliFailed;
    return encoded_len;
}

/// Decodes all of `input` into `output` and returns the decoded length.
/// Fails with `error.BrotliFailed` on corrupt input or when `output` is too
/// small.
pub fn decompress(input: []const u8, output: []u8) !usize {
    var decoded_len: usize = output.len;
    const result: DecoderResult = @enumFromInt(c.BrotliDecoderDecompress(input.len, input.ptr, &decoded_len, output.ptr));
    if (result != .success)
        return error.BrotliFailed;
    return decoded_len;
}
