// CompressionStream and DecompressionStream (Compression standard): the codec steps and the cell that joins a
// readable and a writable stream around one codec. Runs on the VM thread.
//
// At most one write or close is pending, because the writable side waits for each sink promise before its next call.
// pump runs the pending operation in two alternating phases. fillOutput runs the codec, with no script, until its
// output reaches WebApiCompressionStreamOutputChunkBytes, its input runs out or the stream ends. deliverOutput then
// enqueues that output as one chunk, which can run script. Output is delivered only while the readable side wants it;
// what it does not want waits in the cell, the unconsumed input waits in the pending operation, and the readable
// side's pull resumes both. The output that ends the compressed stream is the exception: it is enqueued whether or
// not a read waits, as the standard's flush does, so the close can complete.
#include "host_functions/webapi/streams/compression_stream_private.h"

#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/shared_bytes.h"

#include <brotli/decode.h>
#include <brotli/encode.h>
#include <zlib.h>

#include <wtf/FastMalloc.h>
#include <wtf/SetForScope.h>

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

} // namespace

bool parseCompressionFormat(WTF::String format, CompressionFormat& out)
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
        }
        m_kind = Kind::Brotli;
        return true;
    }

    // zlib's windowBits: 15 is the largest window, adding 16 selects the gzip wrapper and negating it selects raw
    // deflate. The 8 passed to deflateInit2 below is zlib's default memLevel.
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
    m_zlib_stream.zalloc = zlibAllocate;
    m_zlib_stream.zfree = zlibDeallocate;
    m_zlib_stream.opaque = this;
    // A failed init frees whatever it allocated.
    const int status = decompressing
        ? inflateInit2(&m_zlib_stream, window_bits)
        : deflateInit2(&m_zlib_stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window_bits, 8, Z_DEFAULT_STRATEGY);
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

static JSColloCompressionStream* compressionStreamFromFunction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
{
    JSC::JSValue value = function->get(global_object, compressionStreamStateIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* stream = dynamicDowncast<JSColloCompressionStream>(value);
    if (!stream)
        JSC::throwVMTypeError(global_object, scope, "CompressionStream state is unavailable"_s);
    return stream;
}

struct CompressionInputBytes {
    std::span<const uint8_t> bytes;
};

// The span borrows the chunk's buffer: it stays valid only until script runs.
static bool compressionInputBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, CompressionInputBytes& out)
{
    out = {};
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (!validateArrayBufferViewForCopy(
                global_object, scope, view, "CompressionStream chunk view is detached or out of bounds"_s))
            return false;
        out.bytes = arrayBufferViewBytes(view);
        return true;
    }

    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        if (!validateArrayBufferForCopy(global_object, scope, array_buffer,
                "CompressionStream chunk must be a fixed-length attached ArrayBuffer"_s))
            return false;
        out.bytes = arrayBufferBytes(array_buffer);
        return true;
    }

    // "compress and enqueue a chunk" and "decompress and enqueue a chunk"
    // accept only a BufferSource and throw a TypeError for anything else.
    JSC::throwVMTypeError(global_object, scope, "CompressionStream chunk must be a BufferSource"_s);
    return false;
}

JSC_DEFINE_HOST_FUNCTION(compressionWriteCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = compressionStreamFromFunction(
        global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    return stream->write(global_object, scope, call_frame->argument(0));
}

JSC_DEFINE_HOST_FUNCTION(compressionCloseCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = compressionStreamFromFunction(
        global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    return stream->close(global_object, scope);
}

JSC_DEFINE_HOST_FUNCTION(compressionAbortCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = compressionStreamFromFunction(
        global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    stream->abort(global_object, call_frame->argument(0));
    return JSC::JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(compressionPullCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = compressionStreamFromFunction(
        global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    stream->resume(global_object, scope);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(compressionCancelCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = compressionStreamFromFunction(
        global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    stream->readableCanceled(global_object, call_frame->argument(0));
    return JSC::JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    compressionChunkSizeCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSValue chunk = call_frame->argument(0);
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(chunk)) {
        if (arrayBufferViewIsUnavailable(view))
            return JSC::JSValue::encode(JSC::jsNumber(0));
        return JSC::JSValue::encode(JSC::jsNumber(view->byteLength()));
    }
    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(chunk)) {
        if (arrayBufferIsUnavailableForCopy(array_buffer))
            return JSC::JSValue::encode(JSC::jsNumber(0));
        return JSC::JSValue::encode(JSC::jsNumber(arrayBufferBytes(array_buffer).size()));
    }
    auto string = chunk.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(JSC::jsNumber(string.length()));
}

static JSC::JSValue createCompressionCallback(JSC::JSGlobalObject* global_object, JSColloCompressionStream* stream,
    WTF::ASCIILiteral name, JSC::NativeFunction callback, unsigned length)
{
    auto& vm = global_object->vm();
    auto* function
        = JSC::JSFunction::create(vm, global_object, length, name, callback, JSC::ImplementationVisibility::Public);
    function->putDirect(vm, compressionStreamStateIdentifier(global_object), stream,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return function;
}

bool JSColloCompressionStream::initialize(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, CompressionFormat format, bool decompressing)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    // The pinned libraries accept every format and parameter used here, so only an allocation can fail.
    if (!m_codec.open(format, decompressing)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    m_decompressing = decompressing;
    noteMemoryCost();

    auto* readable = JSColloReadableStream::create(vm, collo_global);
    auto* readable_controller = JSColloReadableStreamDefaultController::create(vm, global_object, readable);
    readable->setController(vm, readable_controller);
    // The Compression standard sets up its TransformStream with the default
    // high-water marks, 0 for the readable side and 1 for the writable side
    // below, so a write stays pending until the readable side pulls.
    readable->setHighWaterMark(0);
    JSC::JSValue pull_function
        = createCompressionCallback(global_object, this, "CompressionStream pull"_s, compressionPullCallback, 0);
    JSC::JSValue cancel_function
        = createCompressionCallback(global_object, this, "CompressionStream cancel"_s, compressionCancelCallback, 1);
    JSC::JSValue size_function
        = createCompressionCallback(global_object, this, "CompressionStream size"_s, compressionChunkSizeCallback, 1);
    readable_controller->setCallbacks(vm, pull_function, cancel_function, size_function);
    m_readable.set(vm, this, readable);

    JSC::JSValue write_function
        = createCompressionCallback(global_object, this, "CompressionStream write"_s, compressionWriteCallback, 1);
    JSC::JSValue close_function
        = createCompressionCallback(global_object, this, "CompressionStream close"_s, compressionCloseCallback, 0);
    JSC::JSValue abort_function
        = createCompressionCallback(global_object, this, "CompressionStream abort"_s, compressionAbortCallback, 1);
    auto* writable = createWritableStreamFromCallbacks(global_object, scope, JSC::jsUndefined(), write_function,
        close_function, abort_function, JSC::jsUndefined(), 1);
    RETURN_IF_EXCEPTION(scope, false);
    if (!writable)
        return false;
    m_writable.set(vm, this, writable);
    return true;
}

void JSColloCompressionStream::noteMemoryCost()
{
    const size_t cost = m_codec.allocatedBytes() + m_pending_input.capacity() + m_output.capacity();
    m_memory_cost.store(cost, std::memory_order_relaxed);
    if (cost <= m_memory_cost_reported)
        return;
    const size_t growth = cost - m_memory_cost_reported;
    m_memory_cost_reported = cost;
    vm().heap.reportExtraMemoryAllocated(this, growth);
}

bool JSColloCompressionStream::readableWantsOutput() const
{
    auto* readable_stream = readable();
    if (!readable_stream || readable_stream->state() != StreamState::Readable)
        return false;
    return readable_stream->hasPendingReadRequests() || readable_stream->desiredSize() > 0;
}

bool JSColloCompressionStream::beginOperation(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, PendingOperation operation)
{
    if (m_pending_operation != PendingOperation::None) {
        JSC::throwVMTypeError(global_object, scope, "CompressionStream already has a pending operation"_s);
        return false;
    }
    // An operation ends only with its input consumed and its output delivered, or by takePendingOperation.
    ASSERT(m_pending_input.isEmpty());
    ASSERT(m_output.isEmpty());
    m_pending_promise.set(global_object->vm(), this, Collo::newPromise(global_object));
    m_pending_operation = operation;
    return true;
}

std::span<const uint8_t> JSColloCompressionStream::pendingInput() const
{
    return m_pending_input.span().subspan(m_pending_offset);
}

void JSColloCompressionStream::consumePendingInput(size_t consumed)
{
    ASSERT(consumed <= m_pending_input.size() - m_pending_offset);
    m_pending_offset += consumed;
    if (m_pending_offset == m_pending_input.size()) {
        m_pending_input.clear();
        m_pending_offset = 0;
    }
}

bool JSColloCompressionStream::keepInput(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> borrowed_input)
{
    if (borrowed_input.empty())
        return true;
    // A write's input is borrowed until the first time it is kept, and owned from then on.
    ASSERT(m_pending_input.isEmpty());
    if (!m_pending_input.tryAppend(borrowed_input)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    m_pending_offset = 0;
    noteMemoryCost();
    return true;
}

CodecStatus JSColloCompressionStream::fillOutput(std::span<const uint8_t> input, bool finish, size_t& consumed)
{
    ASSERT(m_output.isEmpty());
    consumed = 0;
    if (!m_output.tryReserveCapacity(WebApiCompressionStreamOutputChunkBytes))
        return CodecStatus::OutOfMemory;
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

bool JSColloCompressionStream::deliverOutput(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    ASSERT(!m_output.isEmpty());
    auto* readable_stream = readable();
    if (!readable_stream) {
        JSC::throwVMTypeError(global_object, scope, "CompressionStream readable side is unavailable"_s);
        return false;
    }
    JSC::JSUint8Array* chunk = nullptr;
    if (m_output.size() == m_output.capacity()) {
        // A full buffer becomes the chunk's storage without a copy.
        const size_t length = m_output.size();
        auto bytes = ColloSharedBytes::create(std::exchange(m_output, {}));
        noteMemoryCost();
        if (!bytes) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        chunk = createUint8ArrayFromExclusiveSharedBytes(global_object, scope, bytes.releaseNonNull(), 0, length);
    } else {
        // A partial one is copied, so the chunk keeps no unused capacity alive.
        chunk = createUint8ArrayCopy(global_object, scope, m_output.span());
        m_output.clear();
        noteMemoryCost();
    }
    RETURN_IF_EXCEPTION(scope, false);
    readable_stream->enqueue(global_object, scope, chunk);
    RETURN_IF_EXCEPTION(scope, false);
    return true;
}

JSColloCompressionStream::PumpResult JSColloCompressionStream::pump(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> borrowed_input)
{
    ASSERT(m_pending_operation != PendingOperation::None);
    ASSERT(!m_pumping);
    WTF::SetForScope<bool> pumping { m_pumping, true };
    auto* operation = m_pending_promise.get();
    const bool finishing = m_pending_operation == PendingOperation::Close;
    ASSERT(!finishing || borrowed_input.empty());

    while (true) {
        // A delivery runs script: no borrowed span is alive across it, and the state is read again after it.
        while (!m_output.isEmpty()) {
            ASSERT(borrowed_input.empty());
            if (!m_codec.finished() && !readableWantsOutput())
                return PumpResult::Blocked;
            if (!deliverOutput(global_object, scope))
                return PumpResult::Threw;
            if (m_pending_promise.get() != operation)
                return PumpResult::Superseded;
        }

        const bool borrowing = !borrowed_input.empty();
        const auto input = borrowing ? borrowed_input : pendingInput();
        if (finishing) {
            if (m_codec.finished())
                return PumpResult::Complete;
        } else {
            if (input.empty() && !m_codec_has_more_output)
                return PumpResult::Complete;
            // Input after the end of the compressed stream.
            if (m_codec.finished())
                return PumpResult::CodecFailed;
            if (!readableWantsOutput()) {
                if (!keepInput(global_object, scope, borrowed_input))
                    return PumpResult::Threw;
                return PumpResult::Blocked;
            }
        }

        size_t consumed = 0;
        const CodecStatus status = fillOutput(input, finishing, consumed);
        m_codec_has_more_output = status == CodecStatus::MoreOutput;
        if (borrowing)
            borrowed_input = borrowed_input.subspan(consumed);
        else
            consumePendingInput(consumed);
        // A codec that is finishing has all its input, so asking for more is a failure, and pumping again would spin.
        if (status == CodecStatus::Failed || (finishing && status == CodecStatus::NeedsInput))
            return PumpResult::CodecFailed;
        if (status == CodecStatus::OutOfMemory) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return PumpResult::Threw;
        }
        // Deliveries run script from here on, so whatever the codec left of a borrowed chunk is copied now.
        if (!keepInput(global_object, scope, borrowed_input))
            return PumpResult::Threw;
        borrowed_input = {};
        noteMemoryCost();
    }
}

JSC::JSPromise* JSColloCompressionStream::takePendingOperation()
{
    auto* promise = m_pending_promise.get();
    m_pending_promise.clear();
    m_pending_operation = PendingOperation::None;
    m_pending_input.clear();
    m_pending_offset = 0;
    m_output.clear();
    m_codec_has_more_output = false;
    noteMemoryCost();
    return promise;
}

void JSColloCompressionStream::completePendingOperation(JSC::JSGlobalObject* global_object)
{
    const bool closing = m_pending_operation == PendingOperation::Close;
    // Closing the readable side settles its pending reads, which runs script, so the operation is detached first.
    auto* promise = takePendingOperation();
    if (closing) {
        if (auto* readable_stream = readable())
            readable_stream->close(global_object);
    }
    // settlePromise refuses while a termination that script raised is pending, and then nothing is left to undo.
    (void)Collo::settlePromise(promise, JSC::jsUndefined(), false);
}

void JSColloCompressionStream::rejectPendingOperation(JSC::JSValue reason)
{
    if (m_pending_operation == PendingOperation::None)
        return;
    auto* promise = takePendingOperation();
    // When the sink callback threw instead of returning this promise, nothing observes it, and the writable side
    // reports the failure itself.
    promise->markAsHandled();
    (void)Collo::settlePromise(promise, reason, true);
}

void JSColloCompressionStream::failBothSides(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    if (auto* readable_stream = readable())
        readable_stream->error(global_object, reason);
    m_codec.release();
    rejectPendingOperation(reason);
    noteMemoryCost();
}

JSC::EncodedJSValue JSColloCompressionStream::drivePendingOperation(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> borrowed_input)
{
    auto* promise = m_pending_promise.get();
    const PumpResult result = pump(global_object, scope, borrowed_input);
    if (auto* exception = scope.exception()) {
        ASSERT(result == PumpResult::Threw);
        JSC::JSValue reason = exception->value();
        if (!scope.tryClearException()) {
            // A termination stays pending and ends the request. Free the native state, settle nothing, and let it
            // unwind.
            m_codec.release();
            if (m_pending_promise.get() == promise)
                (void)takePendingOperation();
            noteMemoryCost();
            return {};
        }
        if (m_pending_promise.get() == promise)
            failBothSides(global_object, reason);
        JSC::throwException(global_object, scope, reason);
        return {};
    }

    switch (result) {
    case PumpResult::Complete:
        completePendingOperation(global_object);
        break;
    case PumpResult::CodecFailed:
        // The Compression standard reports every codec failure as a TypeError.
        failBothSides(global_object,
            JSC::createTypeError(global_object,
                m_decompressing ? "DecompressionStream input is not valid compressed data"_s
                                : "CompressionStream could not compress its input"_s));
        break;
    case PumpResult::Blocked:
    case PumpResult::Superseded:
    case PumpResult::Threw:
        break;
    }
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

JSC::EncodedJSValue JSColloCompressionStream::write(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
{
    CompressionInputBytes input;
    if (!compressionInputBytes(global_object, scope, chunk, input))
        return {};
    if (!beginOperation(global_object, scope, PendingOperation::Write))
        return {};
    // beginOperation allocates but runs no script, so the chunk's bytes are still the ones validated above.
    return drivePendingOperation(global_object, scope, input.bytes);
}

JSC::EncodedJSValue JSColloCompressionStream::close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!beginOperation(global_object, scope, PendingOperation::Close))
        return {};
    return drivePendingOperation(global_object, scope, {});
}

void JSColloCompressionStream::resume(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    // A pull that script starts during a delivery finds pump running, and pump re-checks demand after every delivery.
    if (m_pumping || m_pending_operation == PendingOperation::None)
        return;
    (void)drivePendingOperation(global_object, scope, {});
}

void JSColloCompressionStream::readableCanceled(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    const bool had_pending = m_pending_operation != PendingOperation::None;
    m_codec.release();
    // A pending write or close errors the writable side when its rejected
    // promise reaches the writable stream; with none pending, it is errored
    // here.
    rejectPendingOperation(reason);
    if (!had_pending) {
        if (auto* writable_stream = writable())
            writable_stream->error(global_object, reason);
    }
    noteMemoryCost();
}

void JSColloCompressionStream::abort(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    failBothSides(global_object, reason);
}

// CompressionStream and DecompressionStream share one cell class, so the
// direction tells a receiver of one from an instance of the other.
static JSColloCompressionStream* requireCompressionStreamInstance(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, JSC::JSValue value, bool expected_decompression, WTF::ASCIILiteral class_name)
{
    auto* stream = dynamicDowncast<JSColloCompressionStream>(value);
    if (!stream || stream->isDecompression() != expected_decompression) {
        JSC::throwVMTypeError(
            global_object, scope, WTF::makeString(class_name, " method called on incompatible receiver"_s));
        return nullptr;
    }
    return stream;
}

JSC_DEFINE_HOST_FUNCTION(compressionStreamConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "CompressionStream constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    compressionStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto format_string = call_frame->argument(0).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    CompressionFormat format;
    if (!parseCompressionFormat(format_string, format)) {
        JSC::throwException(
            global_object, scope, JSC::createTypeError(global_object, "CompressionStream format is not supported"_s));
        return {};
    }
    auto* structure
        = streamStructureForNewTarget(global_object, scope, call_frame, collo_global->compressionStreamStructure());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = JSColloCompressionStream::createWithStructure(vm, structure);
    if (!stream->initialize(global_object, scope, format, false))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(stream);
}

JSC_DEFINE_HOST_FUNCTION(decompressionStreamConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "DecompressionStream constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    decompressionStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto format_string = call_frame->argument(0).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    CompressionFormat format;
    if (!parseCompressionFormat(format_string, format)) {
        JSC::throwException(
            global_object, scope, JSC::createTypeError(global_object, "DecompressionStream format is not supported"_s));
        return {};
    }
    auto* structure
        = streamStructureForNewTarget(global_object, scope, call_frame, collo_global->decompressionStreamStructure());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = JSColloCompressionStream::createWithStructure(vm, structure);
    if (!stream->initialize(global_object, scope, format, true))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(stream);
}

JSC_DEFINE_HOST_FUNCTION(
    compressionStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = requireCompressionStreamInstance(global_object, scope, call_frame->thisValue(), false, "CompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(stream->readable());
}

JSC_DEFINE_HOST_FUNCTION(
    compressionStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = requireCompressionStreamInstance(global_object, scope, call_frame->thisValue(), false, "CompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(stream->writable());
}

JSC_DEFINE_HOST_FUNCTION(
    decompressionStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireCompressionStreamInstance(
        global_object, scope, call_frame->thisValue(), true, "DecompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(stream->readable());
}

JSC_DEFINE_HOST_FUNCTION(
    decompressionStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireCompressionStreamInstance(
        global_object, scope, call_frame->thisValue(), true, "DecompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(stream->writable());
}
} // namespace Collo::HostFunctions
