// CompressionStream and DecompressionStream: the cell, the codec that drives
// zlib or Brotli, and the part of both libraries' C API the bridge calls. Runs
// on the VM thread.
//
// The bridge loads zlib and Brotli with dlopen instead of including their
// headers, so the constants and ZlibStream below restate zlib.h and the Brotli
// headers and must match them on 64-bit Linux. deflateInit2_ and inflateInit2_
// reject a ZlibStream of the wrong size, but not a reordered field. A codec's
// library state is malloc memory the collector does not see; deinit or the
// cell's destructor frees it.
#pragma once

#include "host_functions/webapi/streams/readable_stream_private.h"
#include "host_functions/webapi/streams/writable_stream_private.h"

#include <cstddef>
#include <cstdint>

namespace Collo::HostFunctions {

JSC_DECLARE_HOST_FUNCTION(compressionStreamConstructorCall);
JSC_DECLARE_HOST_FUNCTION(compressionStreamConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(decompressionStreamConstructorCall);
JSC_DECLARE_HOST_FUNCTION(decompressionStreamConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(compressionStreamGetReadable);
JSC_DECLARE_HOST_FUNCTION(compressionStreamGetWritable);
JSC_DECLARE_HOST_FUNCTION(decompressionStreamGetReadable);
JSC_DECLARE_HOST_FUNCTION(decompressionStreamGetWritable);

enum class CompressionFormat : uint8_t {
    Gzip,
    Deflate,
    DeflateRaw,
    Brotli,
};

enum class CompressionProcessResult : uint8_t {
    Complete,
    Blocked,
    Failed,
};

constexpr int zlibOk = 0;
constexpr int zlibStreamEnd = 1;
constexpr int zlibStreamError = -2;
constexpr int zlibDataError = -3;
constexpr int zlibMemoryError = -4;
constexpr int zlibBufferError = -5;
constexpr int zlibNoFlush = 0;
constexpr int zlibFinish = 4;
constexpr int zlibDeflated = 8;
constexpr int zlibDefaultCompression = -1;
constexpr int zlibDefaultStrategy = 0;
constexpr int brotliEncoderOperationProcess = 0;
constexpr int brotliEncoderOperationFinish = 2;
constexpr int brotliDecoderResultError = 0;
constexpr int brotliDecoderResultSuccess = 1;
constexpr int brotliDecoderResultNeedsMoreInput = 2;
constexpr int brotliDecoderResultNeedsMoreOutput = 3;

struct ZlibStream {
    const uint8_t* next_in { nullptr };
    unsigned int avail_in { 0 };
    unsigned long total_in { 0 };
    uint8_t* next_out { nullptr };
    unsigned int avail_out { 0 };
    unsigned long total_out { 0 };
    const char* msg { nullptr };
    void* state { nullptr };
    void* zalloc { nullptr };
    void* zfree { nullptr };
    void* opaque { nullptr };
    int data_type { 0 };
    unsigned long adler { 0 };
    unsigned long reserved { 0 };
};

using ZlibVersionFn = const char* (*)();
using ZlibDeflateInit2Fn = int (*)(ZlibStream*, int, int, int, int, int, const char*, int);
using ZlibDeflateFn = int (*)(ZlibStream*, int);
using ZlibDeflateEndFn = int (*)(ZlibStream*);
using ZlibInflateInit2Fn = int (*)(ZlibStream*, int, const char*, int);
using ZlibInflateFn = int (*)(ZlibStream*, int);
using ZlibInflateEndFn = int (*)(ZlibStream*);

struct ZlibLibrary {
    bool available { false };
    ZlibVersionFn version { nullptr };
    ZlibDeflateInit2Fn deflate_init { nullptr };
    ZlibDeflateFn deflate { nullptr };
    ZlibDeflateEndFn deflate_end { nullptr };
    ZlibInflateInit2Fn inflate_init { nullptr };
    ZlibInflateFn inflate { nullptr };
    ZlibInflateEndFn inflate_end { nullptr };
};

struct BrotliEncoderState;
struct BrotliDecoderState;

using BrotliAllocFn = void* (*)(void*, size_t);
using BrotliFreeFn = void (*)(void*, void*);
using BrotliEncoderCreateFn = BrotliEncoderState* (*)(BrotliAllocFn, BrotliFreeFn, void*);
using BrotliEncoderDestroyFn = void (*)(BrotliEncoderState*);
using BrotliEncoderCompressStreamFn
    = int (*)(BrotliEncoderState*, int, size_t*, const uint8_t**, size_t*, uint8_t**, size_t*);
using BrotliEncoderIsFinishedFn = int (*)(BrotliEncoderState*);
using BrotliDecoderCreateFn = BrotliDecoderState* (*)(BrotliAllocFn, BrotliFreeFn, void*);
using BrotliDecoderDestroyFn = void (*)(BrotliDecoderState*);
using BrotliDecoderDecompressStreamFn
    = int (*)(BrotliDecoderState*, size_t*, const uint8_t**, size_t*, uint8_t**, size_t*);

struct BrotliLibrary {
    bool available { false };
    BrotliEncoderCreateFn encoder_create { nullptr };
    BrotliEncoderDestroyFn encoder_destroy { nullptr };
    BrotliEncoderCompressStreamFn encoder_compress_stream { nullptr };
    BrotliEncoderIsFinishedFn encoder_is_finished { nullptr };
    BrotliDecoderCreateFn decoder_create { nullptr };
    BrotliDecoderDestroyFn decoder_destroy { nullptr };
    BrotliDecoderDecompressStreamFn decoder_decompress_stream { nullptr };
};

const ZlibLibrary& sharedZlibLibrary();
const BrotliLibrary& sharedBrotliLibrary();
void preloadCompressionLibraries();

class CompressionCodec {
public:
    CompressionCodec() = default;
    CompressionCodec(const CompressionCodec&) = delete;
    CompressionCodec& operator=(const CompressionCodec&) = delete;
    ~CompressionCodec() { deinit(); }

    bool init(CompressionFormat format, bool decompressing)
    {
        m_format = format;
        m_decompressing = decompressing;
        if (format == CompressionFormat::Brotli)
            return initBrotli(decompressing);
        return initZlib(format, decompressing);
    }

    void deinit()
    {
        if (m_kind == Kind::Zlib) {
            if (m_decompressing) {
                if (m_zlib_library && m_zlib_library->inflate_end)
                    m_zlib_library->inflate_end(&m_zlib_stream);
            } else if (m_zlib_library && m_zlib_library->deflate_end) {
                m_zlib_library->deflate_end(&m_zlib_stream);
            }
        } else if (m_kind == Kind::Brotli) {
            if (m_decompressing) {
                if (m_brotli_library && m_brotli_decoder_state && m_brotli_library->decoder_destroy)
                    m_brotli_library->decoder_destroy(m_brotli_decoder_state);
            } else if (m_brotli_library && m_brotli_encoder_state && m_brotli_library->encoder_destroy) {
                m_brotli_library->encoder_destroy(m_brotli_encoder_state);
            }
        }
        m_kind = Kind::None;
        m_zlib_library = nullptr;
        m_brotli_library = nullptr;
        m_brotli_encoder_state = nullptr;
        m_brotli_decoder_state = nullptr;
        m_finished = false;
        m_pending_output.clear();
        m_zlib_stream = {};
    }

    // Feeds input to the codec, with finish set on the last call, and enqueues
    // output on readable while it accepts more. Blocked leaves the unconsumed
    // byte count in remaining_input_size. Failed either leaves an exception
    // pending or, for a codec error, leaves the caller to report one.
    CompressionProcessResult process(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size);

private:
    enum class Kind : uint8_t {
        None,
        Zlib,
        Brotli,
    };

    bool initZlib(CompressionFormat format, bool decompressing)
    {
        const auto& library = sharedZlibLibrary();
        if (!library.available)
            return false;
        // zlib's windowBits: 15 is the largest window, adding 16 selects the
        // gzip wrapper and negating it selects raw deflate. The 8 passed to
        // deflateInit2_ below is zlib's default memLevel.
        const int window_bits = [format] {
            switch (format) {
            case CompressionFormat::Gzip:
                return 15 + 16;
            case CompressionFormat::Deflate:
                return 15;
            case CompressionFormat::DeflateRaw:
                return -15;
            case CompressionFormat::Brotli:
                return 0;
            }
            return 0;
        }();
        m_zlib_stream = {};
        if (decompressing) {
            int status = library.inflate_init(&m_zlib_stream, window_bits, library.version(), sizeof(ZlibStream));
            if (status != zlibOk)
                return false;
        } else {
            int status = library.deflate_init(&m_zlib_stream, zlibDefaultCompression, zlibDeflated, window_bits, 8,
                zlibDefaultStrategy, library.version(), sizeof(ZlibStream));
            if (status != zlibOk)
                return false;
        }
        m_zlib_library = &library;
        m_kind = Kind::Zlib;
        return true;
    }

    bool initBrotli(bool decompressing)
    {
        const auto& library = sharedBrotliLibrary();
        if (!library.available)
            return false;
        if (decompressing) {
            m_brotli_decoder_state = library.decoder_create(nullptr, nullptr, nullptr);
            if (!m_brotli_decoder_state)
                return false;
        } else {
            m_brotli_encoder_state = library.encoder_create(nullptr, nullptr, nullptr);
            if (!m_brotli_encoder_state)
                return false;
        }
        m_brotli_library = &library;
        m_kind = Kind::Brotli;
        return true;
    }

    bool readableCanAcceptOutput(JSColloReadableStream* readable) const;
    // force skips the demand check. flushPendingOutput sets it after checking
    // demand itself, and the codec loops set it for the output that completes
    // the compressed stream.
    CompressionProcessResult appendOutput(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSColloReadableStream* readable, std::span<const uint8_t> bytes, bool force);
    CompressionProcessResult flushPendingOutput(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloReadableStream* readable);
    CompressionProcessResult processZlib(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size);
    CompressionProcessResult processBrotli(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size);
    CompressionProcessResult processBrotliEncoder(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size);
    CompressionProcessResult processBrotliDecoder(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size);

    CompressionFormat m_format { CompressionFormat::Gzip };
    Kind m_kind { Kind::None };
    bool m_decompressing { false };
    bool m_finished { false };
    WTF::Vector<uint8_t> m_pending_output;

    const ZlibLibrary* m_zlib_library { nullptr };
    const BrotliLibrary* m_brotli_library { nullptr };

    ZlibStream m_zlib_stream;
    BrotliEncoderState* m_brotli_encoder_state { nullptr };
    BrotliDecoderState* m_brotli_decoder_state { nullptr };
};

bool parseCompressionFormat(WTF::String, CompressionFormat&);

class JSColloCompressionStream final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloCompressionStream* createWithStructure(JSC::VM& vm, JSC::Structure* structure)
    {
        auto* object
            = new (NotNull, JSC::allocateCell<JSColloCompressionStream>(vm)) JSColloCompressionStream(vm, structure);
        object->finishCreation(vm);
        return object;
    }

    static void destroy(JSCell* cell) { static_cast<JSColloCompressionStream*>(cell)->~JSColloCompressionStream(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    bool isDecompression() const { return m_decompressing; }
    JSColloReadableStream* readable() const { return m_readable.get(); }
    JSColloWritableStream* writable() const { return m_writable.get(); }

    bool initialize(JSC::JSGlobalObject*, JSC::ThrowScope&, CompressionFormat, bool decompressing);
    EncodedJSValue write(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue chunk);
    EncodedJSValue close(JSC::JSGlobalObject*, JSC::ThrowScope&);
    void resume(JSC::JSGlobalObject*, JSC::ThrowScope&);
    void readableCanceled(JSC::JSGlobalObject*, JSValue reason);
    void abort(JSC::JSGlobalObject*, JSValue reason);

private:
    enum class PendingOperation : uint8_t {
        None,
        Write,
        Close,
    };

    explicit JSColloCompressionStream(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloCompressionStream()
    {
        if (m_pending_deferred)
            collo_promise_deferred_release(m_pending_deferred);
    }

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
    }

    bool setPendingOperation(JSC::JSGlobalObject*, JSC::ThrowScope&, PendingOperation, std::span<const uint8_t>);
    CompressionProcessResult pumpPendingOperation(JSC::JSGlobalObject*, JSC::ThrowScope&);
    EncodedJSValue drivePendingOperation(JSC::JSGlobalObject*, JSC::ThrowScope&);
    void resolvePendingOperation(JSC::JSGlobalObject*);
    void rejectPendingOperation(JSC::JSGlobalObject*, JSValue reason);
    void failBothSides(JSC::JSGlobalObject*, JSValue reason);
    void clearPendingOperation();

    JSC::WriteBarrier<JSColloReadableStream> m_readable;
    JSC::WriteBarrier<JSColloWritableStream> m_writable;
    JSC::WriteBarrier<JSC::Unknown> m_pending_promise;
    CompressionCodec m_codec;
    // A copy of the pending write's chunk: a blocked write resumes on a later
    // pull, after script may have detached or changed the chunk's buffer.
    WTF::Vector<uint8_t> m_pending_input;
    size_t m_pending_offset { 0 };
    // Can keep this cell alive until VM teardown: see the FIXME in stream_common_private.h.
    ColloPromiseDeferred* m_pending_deferred { nullptr };
    PendingOperation m_pending_operation { PendingOperation::None };
    bool m_decompressing { false };
};

} // namespace Collo::HostFunctions
