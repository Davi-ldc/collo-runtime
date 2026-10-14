// CompressionStream and DecompressionStream (Compression Standard): the codec steps, the native transformer that a
// transform stream drives, and the two interfaces. Runs on the VM thread.
//
// The stream hands the transformer a chunk only once the readable side has pulled since the last output. The
// transformer copies it into its pending input and turns it into output only when the stream asks, which it does while
// the readable side wants output:
// one produce() fills at most WebApiCompressionStreamOutputChunkBytes of output with no script running, and the stream
// enqueues it. So what the readable side does not want stays as input in the transformer, and a write settles once its
// input is consumed and its output enqueued; the input buffer is freed once consumed, so its peak does not outlive the
// write. What close() leaves is what the codec buffered plus its end, bounded by the codec's own state and not by the
// input: a decompressor has produced all its output by then and only checks that the compressed data ended. The codec
// opens on the first write the stream hands over or on close, so a stream nobody reads holds no library state.

#include "host_functions/webapi/streams/compression_stream_private.h"

#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/transform_stream.h"

#include <wtf/FastMalloc.h>

#include <algorithm>
#include <cstddef>
#include <limits>
#include <new>
#include <utility>

namespace Collo::HostFunctions {

namespace {

    // Each library allocation is prefixed with its size, so its free can be counted. The prefix keeps the payload at
    // the alignment malloc guarantees.
    struct alignas(alignof(std::max_align_t)) CodecAllocationHeader {
        size_t size;
    };

    static_assert(sizeof(size_t) >= 2 * sizeof(uInt), "a zlib allocation's byte count fits in size_t");

    // The Brotli encoder's library defaults (quality 11 with a 4 MiB window) build hash tables and a ring buffer far
    // larger than one stream should hold in a worker. Quality 5 keeps a hasher whose tables are sized by the window,
    // and a 64 KiB window bounds them, so the encoder's state stays within a few MiB whatever the body's size, while
    // its output stays smaller than gzip's.
    constexpr int brotli_encoder_quality = 5;
    constexpr int brotli_encoder_window_bits = 16;
    static_assert(brotli_encoder_window_bits >= BROTLI_MIN_WINDOW_BITS);
    static_assert(brotli_encoder_window_bits <= BROTLI_MAX_WINDOW_BITS);

    // zlib's windowBits: 15 is the largest window, adding 16 selects the gzip wrapper and negating it selects raw
    // deflate. zlib_memory_level is zlib's default memLevel.
    constexpr int zlib_window_bits = 15;
    constexpr int zlib_gzip_wrapper_bits = 16;
    constexpr int zlib_memory_level = 8;

} // namespace

bool parseCompressionFormat(const WTF::String& format, CompressionFormat& out)
{
    if (format == "gzip"_s) {
        out = CompressionFormat::Gzip;
        return true;
    }
    if (format == "deflate"_s) {
        out = CompressionFormat::Deflate;
        return true;
    }
    if (format == "deflate-raw"_s) {
        out = CompressionFormat::DeflateRaw;
        return true;
    }
    if (format == "brotli"_s) {
        out = CompressionFormat::Brotli;
        return true;
    }
    return false;
}

void* CompressionCodec::allocate(void* opaque, size_t size)
{
    auto* codec = static_cast<CompressionCodec*>(opaque);
    if (size > std::numeric_limits<size_t>::max() - sizeof(CodecAllocationHeader)) {
        codec->m_allocation_failed = true;
        return nullptr;
    }
    const size_t total = size + sizeof(CodecAllocationHeader);
    void* memory = nullptr;
    if (!WTF::tryFastMalloc(total).getValue(memory)) {
        codec->m_allocation_failed = true;
        return nullptr;
    }
    codec->m_allocated_bytes += total;
    auto* header = new (NotNull, memory) CodecAllocationHeader { total };
    return header + 1;
}

void CompressionCodec::deallocate(void* opaque, void* address)
{
    if (!address)
        return;
    auto* codec = static_cast<CompressionCodec*>(opaque);
    auto* header = static_cast<CodecAllocationHeader*>(address) - 1;
    ASSERT(header->size <= codec->m_allocated_bytes);
    codec->m_allocated_bytes -= header->size;
    WTF::fastFree(header);
}

voidpf CompressionCodec::zlibAllocate(voidpf opaque, uInt items, uInt size)
{
    return allocate(opaque, static_cast<size_t>(items) * size);
}

void CompressionCodec::zlibDeallocate(voidpf opaque, voidpf address) { deallocate(opaque, address); }

bool CompressionCodec::open(CompressionFormat format, bool decompressing)
{
    ASSERT(m_kind == Kind::None);
    m_decompressing = decompressing;
    m_finished = false;
    if (format == CompressionFormat::Brotli) {
        if (decompressing) {
            m_brotli_decoder_state = BrotliDecoderCreateInstance(allocate, deallocate, this);
            if (!m_brotli_decoder_state)
                return false;
        } else {
            m_brotli_encoder_state = BrotliEncoderCreateInstance(allocate, deallocate, this);
            if (!m_brotli_encoder_state)
                return false;
            if (!BrotliEncoderSetParameter(m_brotli_encoder_state, BROTLI_PARAM_QUALITY, brotli_encoder_quality)
                || !BrotliEncoderSetParameter(m_brotli_encoder_state, BROTLI_PARAM_LGWIN, brotli_encoder_window_bits)) {
                BrotliEncoderDestroyInstance(m_brotli_encoder_state);
                m_brotli_encoder_state = nullptr;
                return false;
            }
        }
        m_kind = Kind::Brotli;
        return true;
    }

    const int window_bits = [format] {
        switch (format) {
        case CompressionFormat::Gzip:
            return zlib_window_bits + zlib_gzip_wrapper_bits;
        case CompressionFormat::Deflate:
            return zlib_window_bits;
        case CompressionFormat::DeflateRaw:
            return -zlib_window_bits;
        case CompressionFormat::Brotli:
            return 0;
        }
        return 0;
    }();
    m_zlib_stream = {};
    m_zlib_stream.zalloc = zlibAllocate;
    m_zlib_stream.zfree = zlibDeallocate;
    m_zlib_stream.opaque = this;
    // A failed init frees whatever it allocated.
    const int status = decompressing ? inflateInit2(&m_zlib_stream, window_bits)
                                     : deflateInit2(&m_zlib_stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window_bits,
                                           zlib_memory_level, Z_DEFAULT_STRATEGY);
    if (status != Z_OK) {
        m_zlib_stream = {};
        return false;
    }
    m_kind = Kind::Zlib;
    return true;
}

void CompressionCodec::release()
{
    switch (m_kind) {
    case Kind::None:
        break;
    case Kind::Zlib:
        if (m_decompressing)
            inflateEnd(&m_zlib_stream);
        else
            deflateEnd(&m_zlib_stream);
        break;
    case Kind::Brotli:
        if (m_brotli_decoder_state)
            BrotliDecoderDestroyInstance(m_brotli_decoder_state);
        if (m_brotli_encoder_state)
            BrotliEncoderDestroyInstance(m_brotli_encoder_state);
        break;
    }
    m_kind = Kind::None;
    m_zlib_stream = {};
    m_brotli_encoder_state = nullptr;
    m_brotli_decoder_state = nullptr;
    ASSERT(!m_allocated_bytes);
}

CodecStep CompressionCodec::step(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output)
{
    ASSERT(!finish || input.empty());
    ASSERT(!output.empty());
    if (m_finished)
        return { input.empty() ? CodecStatus::Finished : CodecStatus::Failed, 0, 0 };

    m_allocation_failed = false;
    CodecStep result;
    switch (m_kind) {
    case Kind::None:
        // release() ran after an error, a cancel or an abort.
        return result;
    case Kind::Zlib:
        result = stepZlib(input, finish, output);
        break;
    case Kind::Brotli:
        result = m_decompressing ? stepBrotliDecoder(input, finish, output) : stepBrotliEncoder(input, finish, output);
        break;
    }
    if (result.status == CodecStatus::Failed && m_allocation_failed)
        result.status = CodecStatus::OutOfMemory;
    if (result.status == CodecStatus::Finished) {
        // "decompress and enqueue a chunk" throws when the compressed stream ends before the chunk does.
        if (result.consumed < input.size())
            result.status = CodecStatus::Failed;
        else
            m_finished = true;
        release();
    }
    return result;
}

CodecStep CompressionCodec::stepZlib(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output)
{
    // zlib counts in uInt. A longer input goes in parts: the caller's loop comes back for the rest.
    const auto input_part = input.first(std::min<size_t>(input.size(), std::numeric_limits<uInt>::max()));
    const auto output_part = output.first(std::min<size_t>(output.size(), std::numeric_limits<uInt>::max()));
    m_zlib_stream.next_in = input_part.data();
    m_zlib_stream.avail_in = static_cast<uInt>(input_part.size());
    m_zlib_stream.next_out = output_part.data();
    m_zlib_stream.avail_out = static_cast<uInt>(output_part.size());
    // inflate treats Z_FINISH like Z_NO_FLUSH apart from its return value, so only deflate is asked to finish.
    const int flush = finish && !m_decompressing ? Z_FINISH : Z_NO_FLUSH;
    const int status = m_decompressing ? inflate(&m_zlib_stream, flush) : deflate(&m_zlib_stream, flush);
    const size_t input_left = m_zlib_stream.avail_in;
    const size_t output_left = m_zlib_stream.avail_out;
    // The library state keeps no pointer into the caller's buffers once the step returns.
    m_zlib_stream.next_in = nullptr;
    m_zlib_stream.avail_in = 0;
    m_zlib_stream.next_out = nullptr;
    m_zlib_stream.avail_out = 0;

    CodecStep result { CodecStatus::Failed, input_part.size() - input_left, output_part.size() - output_left };
    switch (status) {
    case Z_STREAM_END:
        result.status = CodecStatus::Finished;
        break;
    case Z_OK:
    case Z_BUF_ERROR:
        // Z_BUF_ERROR only means this call could make no progress. Both libraries' calls run until the input or the
        // output runs out, so stopping with room left and input left is a failure, and running out of input while
        // finishing means the compressed data ended early.
        if (!output_left)
            result.status = CodecStatus::MoreOutput;
        else if (input_left || finish)
            result.status = CodecStatus::Failed;
        else
            result.status = CodecStatus::NeedsInput;
        break;
    case Z_MEM_ERROR:
        result.status = CodecStatus::OutOfMemory;
        break;
    default:
        // Z_DATA_ERROR, Z_STREAM_ERROR, and Z_NEED_DICT: no preset dictionary is ever supplied.
        result.status = CodecStatus::Failed;
        break;
    }
    return result;
}

CodecStep CompressionCodec::stepBrotliEncoder(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output)
{
    size_t available_in = input.size();
    const uint8_t* next_in = input.data();
    size_t available_out = output.size();
    uint8_t* next_out = output.data();
    const BrotliEncoderOperation operation = finish ? BROTLI_OPERATION_FINISH : BROTLI_OPERATION_PROCESS;
    const BROTLI_BOOL ok = BrotliEncoderCompressStream(
        m_brotli_encoder_state, operation, &available_in, &next_in, &available_out, &next_out, nullptr);

    CodecStep result { CodecStatus::Failed, input.size() - available_in, output.size() - available_out };
    if (!ok)
        return result;
    if (finish && BrotliEncoderIsFinished(m_brotli_encoder_state))
        result.status = CodecStatus::Finished;
    else if (finish || available_in || BrotliEncoderHasMoreOutput(m_brotli_encoder_state))
        result.status = CodecStatus::MoreOutput;
    else
        result.status = CodecStatus::NeedsInput;
    return result;
}

CodecStep CompressionCodec::stepBrotliDecoder(std::span<const uint8_t> input, bool finish, std::span<uint8_t> output)
{
    size_t available_in = input.size();
    const uint8_t* next_in = input.data();
    size_t available_out = output.size();
    uint8_t* next_out = output.data();
    const BrotliDecoderResult status = BrotliDecoderDecompressStream(
        m_brotli_decoder_state, &available_in, &next_in, &available_out, &next_out, nullptr);

    CodecStep result { CodecStatus::Failed, input.size() - available_in, output.size() - available_out };
    switch (status) {
    case BROTLI_DECODER_RESULT_SUCCESS:
        result.status = CodecStatus::Finished;
        break;
    case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
        result.status = CodecStatus::MoreOutput;
        break;
    case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT:
        // Finishing means no input follows, so the compressed data ended early.
        result.status = finish ? CodecStatus::Failed : CodecStatus::NeedsInput;
        break;
    case BROTLI_DECODER_RESULT_ERROR:
        result.status = CodecStatus::Failed;
        break;
    }
    return result;
}

namespace {

    class CompressionStreamTransformer final : public TransformStreamNativeTransformer {
    public:
        static WTF::RefPtr<CompressionStreamTransformer> create(CompressionFormat format, bool decompressing)
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(CompressionStreamTransformer)).getValue(storage))
                return nullptr;
            auto* transformer = new (NotNull, storage) CompressionStreamTransformer(format, decompressing);
            return adoptRef(*transformer);
        }

        bool write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk) override
        {
            std::span<const uint8_t> bytes;
            // "compress and enqueue a chunk" and "decompress and enqueue a chunk" accept only a BufferSource, which
            // has no [AllowShared]: a SharedArrayBuffer, or a view on one, is refused like any other non-BufferSource.
            if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(chunk)) {
                if (view->isShared()) {
                    JSC::throwVMTypeError(
                        global_object, scope, "CompressionStream chunk must not be backed by a SharedArrayBuffer"_s);
                    return false;
                }
                if (!validateArrayBufferViewForCopy(
                        global_object, scope, view, "CompressionStream chunk view is detached or out of bounds"_s))
                    return false;
                bytes = arrayBufferViewBytes(view);
            } else if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(chunk)) {
                if (array_buffer->isShared()) {
                    JSC::throwVMTypeError(
                        global_object, scope, "CompressionStream chunk must not be a SharedArrayBuffer"_s);
                    return false;
                }
                if (!validateArrayBufferForCopy(global_object, scope, array_buffer,
                        "CompressionStream chunk must be a fixed-length attached ArrayBuffer"_s))
                    return false;
                bytes = arrayBufferBytes(array_buffer);
            } else {
                JSC::throwVMTypeError(global_object, scope, "CompressionStream chunk must be a BufferSource"_s);
                return false;
            }
            if (!ensureOpen(global_object, scope))
                return false;
            // The chunk is copied: its buffer can change once script runs, and the input waits for demand.
            if (!m_input.tryAppend(bytes)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            return true;
        }

        bool close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
        {
            // A stream closed before any write still produces a whole compressed stream.
            if (!ensureOpen(global_object, scope))
                return false;
            m_closed = true;
            return true;
        }

        bool hasPendingOutput() const override
        {
            if (m_released)
                return false;
            if (pendingInput().size() || m_codec_has_more_output)
                return true;
            return m_closed && !m_codec.finished();
        }

        JSC::JSValue produce(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
        {
            auto input = pendingInput();
            // Once the writable side closed and every written byte went in, each step finishes the stream.
            const bool finishing = m_closed && input.empty();
            if (!m_output.tryReserveCapacity(WebApiCompressionStreamOutputChunkBytes)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            size_t consumed = 0;
            const CodecStatus status = fillOutput(input, finishing, consumed);
            consumeInput(consumed);
            m_codec_has_more_output = status == CodecStatus::MoreOutput;
            if (status == CodecStatus::OutOfMemory) {
                m_output.shrink(0);
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            // A codec that is finishing has all its input, so asking for more means the compressed data ended early.
            if (status == CodecStatus::Failed || (finishing && status == CodecStatus::NeedsInput)) {
                m_output.shrink(0);
                // The Compression Standard reports every codec failure as a TypeError.
                JSC::throwVMTypeError(global_object, scope,
                    m_decompressing ? "DecompressionStream input is not valid compressed data"_s
                                    : "CompressionStream could not compress its input"_s);
                return {};
            }
            if (m_output.isEmpty())
                return {};
            return takeOutput(global_object, scope);
        }

        void release() override
        {
            m_released = true;
            m_codec.release();
            m_input = {};
            m_input_offset = 0;
            m_output = {};
            m_codec_has_more_output = false;
        }

        size_t memoryCost() const override
        {
            return m_codec.allocatedBytes() + m_input.capacity() + m_output.capacity();
        }

    private:
        CompressionStreamTransformer(CompressionFormat format, bool decompressing)
            : m_format(format)
            , m_decompressing(decompressing)
        {
        }

        bool ensureOpen(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (m_codec.isOpen() || m_codec.finished())
                return true;
            // The pinned libraries accept every format and parameter used here, so only an allocation can fail.
            if (m_codec.open(m_format, m_decompressing))
                return true;
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        std::span<const uint8_t> pendingInput() const { return m_input.span().subspan(m_input_offset); }

        // Keeps m_input_offset below m_input.size(), or both at zero once every byte is consumed. A consumed buffer is
        // freed, not kept for the next write, so one large write's input does not stay allocated, and counted in
        // memoryCost(), for the rest of the stream's life.
        void consumeInput(size_t consumed)
        {
            ASSERT(consumed <= m_input.size() - m_input_offset);
            m_input_offset += consumed;
            if (m_input_offset == m_input.size()) {
                m_input.clear();
                m_input_offset = 0;
            }
        }

        // Runs the codec, with no script, until the output reaches WebApiCompressionStreamOutputChunkBytes, the input
        // runs out, the stream ends or the codec fails.
        CodecStatus fillOutput(std::span<const uint8_t> input, bool finish, size_t& consumed)
        {
            ASSERT(m_output.isEmpty());
            consumed = 0;
            if (m_codec.finished())
                return input.empty() ? CodecStatus::Finished : CodecStatus::Failed;
            while (true) {
                const size_t held = m_output.size();
                if (held == WebApiCompressionStreamOutputChunkBytes)
                    return CodecStatus::MoreOutput;
                // Within the reserved capacity, so this grows without allocating.
                if (!m_output.tryGrow(WebApiCompressionStreamOutputChunkBytes))
                    return CodecStatus::OutOfMemory;
                const auto step = m_codec.step(input.subspan(consumed), finish, m_output.mutableSpan().subspan(held));
                m_output.shrink(held + step.produced);
                consumed += step.consumed;
                switch (step.status) {
                case CodecStatus::NeedsInput:
                    if (consumed == input.size())
                        return CodecStatus::NeedsInput;
                    break;
                case CodecStatus::MoreOutput:
                    break;
                case CodecStatus::Finished:
                case CodecStatus::Failed:
                case CodecStatus::OutOfMemory:
                    return step.status;
                }
                // A step that neither consumes nor produces would repeat forever.
                if (!step.consumed && !step.produced)
                    return CodecStatus::Failed;
            }
        }

        JSC::JSValue takeOutput(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (m_output.size() == m_output.capacity()) {
                // A full buffer becomes the chunk's storage without a copy.
                const size_t length = m_output.size();
                auto bytes = ColloSharedBytes::create(std::exchange(m_output, {}));
                if (!bytes) {
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return {};
                }
                return createUint8ArrayFromExclusiveSharedBytes(
                    global_object, scope, bytes.releaseNonNull(), 0, length);
            }
            // A partial one is copied, so the chunk keeps no unused capacity alive.
            auto* chunk = createUint8ArrayCopy(global_object, scope, m_output.span());
            m_output.shrink(0);
            return chunk;
        }

        CompressionFormat m_format;
        bool m_decompressing { false };
        bool m_closed { false };
        bool m_released { false };
        // The codec's last step stopped early, so it may hold output even with no input left.
        bool m_codec_has_more_output { false };
        CompressionCodec m_codec;
        // Written bytes the codec has not consumed yet, from m_input_offset on; consumeInput() keeps the offset's
        // invariant.
        WTF::Vector<uint8_t> m_input;
        size_t m_input_offset { 0 };
        // The output of one produce(), at most WebApiCompressionStreamOutputChunkBytes; empty between calls.
        WTF::Vector<uint8_t> m_output;
    };

    JSC::EncodedJSValue constructCodecStream(
        JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame, bool decompressing)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto format_string = call_frame->argument(0).toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        CompressionFormat format;
        if (!parseCompressionFormat(format_string, format)) {
            JSC::throwVMTypeError(global_object, scope,
                decompressing ? "DecompressionStream format is not supported"_s
                              : "CompressionStream format is not supported"_s);
            return {};
        }
        auto* base_structure
            = decompressing ? collo_global->decompressionStreamStructure() : collo_global->compressionStreamStructure();
        auto* structure = streamStructureForNewTarget(global_object, scope, call_frame, base_structure);
        RETURN_IF_EXCEPTION(scope, {});
        auto transformer = CompressionStreamTransformer::create(format, decompressing);
        if (!transformer) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto* stream = createNativeTransformStream(global_object, scope, structure,
            decompressing ? TransformStreamKind::DecompressionStream : TransformStreamKind::CompressionStream,
            transformer.releaseNonNull());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(
        compressionStreamConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return constructCodecStream(global_object, call_frame, false);
    }

    JSC_DEFINE_HOST_FUNCTION(
        decompressionStreamConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return constructCodecStream(global_object, call_frame, true);
    }

    // One accessor per side and class: CompressionStream and DecompressionStream are distinct interfaces, so each
    // getter accepts only instances of its own.
    template <TransformStreamKind kind, bool readable_side>
    JSC::EncodedJSValue JSC_HOST_CALL_ATTRIBUTES codecStreamSide(
        JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = transformStreamOfKind(call_frame->thisValue(), kind);
        if (!stream) {
            return JSC::throwVMTypeError(global_object, scope,
                kind == TransformStreamKind::DecompressionStream
                    ? "DecompressionStream method called on incompatible receiver"_s
                    : "CompressionStream method called on incompatible receiver"_s);
        }
        return JSC::JSValue::encode(readable_side ? transformStreamReadable(stream) : transformStreamWritable(stream));
    }

    void installCodecInterface(Collo::GlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name,
        JSC::NativeFunction construct, JSC::NativeFunction readable_getter, JSC::NativeFunction writable_getter,
        JSC::Strong<JSC::Structure>& structure_slot)
    {
        constexpr unsigned accessor_attributes = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
        auto* prototype = JSC::constructEmptyObject(global_object);
        putWebApiAccessor(global_object, prototype, vm, "readable"_s, readable_getter, nullptr, accessor_attributes);
        putWebApiAccessor(global_object, prototype, vm, "writable"_s, writable_getter, nullptr, accessor_attributes);
        installStreamInterface(global_object, vm, name, 1, prototype, construct);
        structure_slot.set(vm, createTransformStreamStructure(vm, global_object, prototype));
    }

} // namespace

void installCompressionStreamClasses(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto& cache = global_object->webApiCache();
    installCodecInterface(global_object, vm, "CompressionStream"_s, compressionStreamConstruct,
        codecStreamSide<TransformStreamKind::CompressionStream, true>,
        codecStreamSide<TransformStreamKind::CompressionStream, false>, cache.compression_stream_structure);
    installCodecInterface(global_object, vm, "DecompressionStream"_s, decompressionStreamConstruct,
        codecStreamSide<TransformStreamKind::DecompressionStream, true>,
        codecStreamSide<TransformStreamKind::DecompressionStream, false>, cache.decompression_stream_structure);
}

} // namespace Collo::HostFunctions
