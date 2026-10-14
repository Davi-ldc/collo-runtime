// CompressionStream and DecompressionStream: the codec that drives zlib or Brotli, under the native transformer that
// compression_stream.cpp gives a transform stream. Runs on the VM thread.
//
// The codec is native only: it never calls into JavaScript and never sees a stream. The bridge compiles zlib.h with
// ZLIB_CONST (addBridgeIncludes in runtime/build/codecs.zig), so z_stream::next_in takes read-only input. Both
// libraries allocate through the codec, which counts their bytes for the stream to report to the collector.

#pragma once

#include "host_functions/webapi/streams/stream_common_private.h"

#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>

#include <cstddef>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions {

enum class CompressionFormat : uint8_t {
    Gzip,
    Deflate,
    DeflateRaw,
    Brotli,
};

enum class CodecStatus : uint8_t {
    // The codec consumed its input and has no output it could produce without more.
    NeedsInput,
    // The codec stopped before it was done, usually because the output span filled. Call it again with the input
    // that remains.
    MoreOutput,
    // The compressed stream ended; the codec has released its library state.
    Finished,
    // Invalid or truncated compressed data, data after the end of the compressed stream, or a library failure.
    Failed,
    // A library allocation failed.
    OutOfMemory,
};

struct CodecStep {
    CodecStatus status { CodecStatus::Failed };
    size_t consumed { 0 };
    size_t produced { 0 };
};

class CompressionCodec {
public:
    CompressionCodec() = default;
    // The libraries hold this codec's address as their allocation context.
    CompressionCodec(const CompressionCodec&) = delete;
    CompressionCodec& operator=(const CompressionCodec&) = delete;
    ~CompressionCodec() { release(); }

    // Returns false when the library cannot allocate its state.
    bool open(CompressionFormat, bool decompressing);
    bool isOpen() const { return m_kind != Kind::None; }
    // Frees the library state. Every later step fails, unless the stream had already finished. Safe to repeat.
    void release();
    bool finished() const { return m_finished; }
    // Bytes the libraries hold right now, allocation headers included.
    size_t allocatedBytes() const { return m_allocated_bytes; }

    // Runs one library call over input into output. finish asks a compressor to end the stream and tells a
    // decompressor that no input follows, which makes a truncated stream fail; it is only passed with empty input.
    // Runs no script. After Finished the codec holds no library state.
    CodecStep step(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output);

private:
    enum class Kind : uint8_t {
        None,
        Zlib,
        Brotli,
    };

    CodecStep stepZlib(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output);
    CodecStep stepBrotliEncoder(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output);
    CodecStep stepBrotliDecoder(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output);

    static void* allocate(void* opaque, size_t size);
    static void deallocate(void* opaque, void* address);
    static voidpf zlibAllocate(voidpf opaque, uInt items, uInt size);
    static void zlibDeallocate(voidpf opaque, voidpf address);

    Kind m_kind { Kind::None };
    bool m_decompressing { false };
    bool m_finished { false };
    // Set by allocate when the library asked for memory it could not get, so a library error reads as OOM.
    bool m_allocation_failed { false };
    size_t m_allocated_bytes { 0 };
    z_stream m_zlib_stream {};
    BrotliEncoderState* m_brotli_encoder_state { nullptr };
    BrotliDecoderState* m_brotli_decoder_state { nullptr };
};

bool parseCompressionFormat(const WTF::String&, CompressionFormat&);

// Defines CompressionStream and DecompressionStream on the realm and caches their instance structures.
void installCompressionStreamClasses(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
