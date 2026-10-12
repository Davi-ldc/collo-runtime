// CompressionStream and DecompressionStream: the cell, and the codec that drives zlib or Brotli. Runs on the VM thread.
//
// The codec is native only: it never calls into JavaScript and never sees a stream. The cell runs it into a held
// output buffer and then delivers that buffer to the readable side. A delivery can run script, because resolving a
// pending read looks up `then` on the read result, and that script can cancel the stream, read again or error it.
// So no span of the input or the output, and no library call, outlives a delivery: the codec has finished its step
// before the cell delivers, and the cell re-reads its state after each delivery.
//
// The bridge compiles zlib.h with ZLIB_CONST (addBridgeIncludes in runtime/build/codecs.zig), so z_stream::next_in
// takes read-only input. Both libraries allocate through the codec, which counts their bytes; the cell reports those
// bytes, with its held input and output, to the collector.
#pragma once

#include "host_functions/webapi/streams/readable_stream_private.h"
#include "host_functions/webapi/streams/writable_stream_private.h"

#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>

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

bool parseCompressionFormat(WTF::String, CompressionFormat&);

class JSColloCompressionStream final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
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

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSColloCompressionStream*>(cell)->~JSColloCompressionStream();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    bool isDecompression() const { return m_decompressing; }
    JSColloReadableStream* readable() const { return m_readable.get(); }
    JSColloWritableStream* writable() const { return m_writable.get(); }

    bool initialize(JSC::JSGlobalObject*, JSC::ThrowScope&, CompressionFormat, bool decompressing);
    JSC::EncodedJSValue write(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk);
    JSC::EncodedJSValue close(JSC::JSGlobalObject*, JSC::ThrowScope&);
    void resume(JSC::JSGlobalObject*, JSC::ThrowScope&);
    void readableCanceled(JSC::JSGlobalObject*, JSC::JSValue reason);
    void abort(JSC::JSGlobalObject*, JSC::JSValue reason);

private:
    enum class PendingOperation : uint8_t {
        None,
        Write,
        Close,
    };

    enum class PumpResult : uint8_t {
        // The operation's input is consumed and its output delivered.
        Complete,
        // The operation waits for the readable side to pull.
        Blocked,
        // Script settled the operation during a delivery, by canceling the readable side.
        Superseded,
        // The codec failed; no exception is pending.
        CodecFailed,
        // An exception is pending.
        Threw,
    };

    explicit JSColloCompressionStream(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
    }

    bool beginOperation(JSC::JSGlobalObject*, JSC::ThrowScope&, PendingOperation);
    JSC::EncodedJSValue drivePendingOperation(
        JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t> borrowed_input);
    PumpResult pump(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t> borrowed_input);
    CodecStatus fillOutput(std::span<const uint8_t> input, bool finish, size_t& consumed);
    bool deliverOutput(JSC::JSGlobalObject*, JSC::ThrowScope&);
    bool keepInput(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t> borrowed_input);
    std::span<const uint8_t> pendingInput() const;
    void consumePendingInput(size_t consumed);
    bool readableWantsOutput() const;
    JSC::JSPromise* takePendingOperation();
    void completePendingOperation(JSC::JSGlobalObject*);
    void rejectPendingOperation(JSC::JSValue reason);
    void failBothSides(JSC::JSGlobalObject*, JSC::JSValue reason);
    void noteMemoryCost();

    JSC::WriteBarrier<JSColloReadableStream> m_readable;
    JSC::WriteBarrier<JSColloWritableStream> m_writable;
    // The promise the writable side waits on for the pending write or close.
    JSC::WriteBarrier<JSC::JSPromise> m_pending_promise;
    CompressionCodec m_codec;
    // What a blocked write has not yet fed to the codec, copied out of its chunk: the write resumes on a later pull,
    // after script may have detached or changed the chunk's buffer.
    WTF::Vector<uint8_t> m_pending_input;
    size_t m_pending_offset { 0 };
    // Codec output not yet delivered, at most WebApiCompressionStreamOutputChunkBytes.
    WTF::Vector<uint8_t> m_output;
    // The codec's last step stopped early, so it may hold output even with no input left.
    bool m_codec_has_more_output { false };
    // True while pump runs. A pull that script triggers during a delivery returns at once, since pump re-checks
    // demand after every delivery.
    bool m_pumping { false };
    PendingOperation m_pending_operation { PendingOperation::None };
    bool m_decompressing { false };
    // The native bytes this cell holds, for visitChildren, which runs on collector threads and reads only this.
    std::atomic<size_t> m_memory_cost { 0 };
    // The most this cell has reported as allocated. Only growth past it is reported again, so output that is handed
    // to the readable side and then replaced does not count as new allocation each time.
    size_t m_memory_cost_reported { 0 };
};

} // namespace Collo::HostFunctions
