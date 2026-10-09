// CompressionStream and DecompressionStream (Compression standard): library
// loading, the codec loops, and the cell that joins a readable and a writable
// stream around one codec. Runs on the VM thread.
//
// The library tables are function-local statics that Web API installation
// fills in the zygote before the first fork, so a worker never calls dlopen.
// The codec enqueues output only while the readable side wants it; what it
// cannot enqueue waits in the codec, the unread input waits in the pending
// operation, and the readable side's pull resumes both. At most one write or
// close is pending, because the writable side waits for each sink promise
// before its next call.
#include "host_functions/webapi/streams/compression_stream_private.h"

#include <array>
#include <dlfcn.h>
#include <initializer_list>
#include <limits>
#include <mutex>

namespace Collo::HostFunctions {

namespace {

    void* openCompressionLibrary(std::initializer_list<const char*> names)
    {
        for (auto* name : names) {
            if (void* handle = dlopen(name, RTLD_LAZY | RTLD_LOCAL))
                return handle;
        }
        return nullptr;
    }

    template <typename T> T lookupCompressionSymbol(void* handle, const char* name)
    {
        if (!handle)
            return nullptr;
        return reinterpret_cast<T>(dlsym(handle, name));
    }

} // namespace

const ZlibLibrary& sharedZlibLibrary()
{
    static std::once_flag once;
    static ZlibLibrary library;
    std::call_once(once, [] {
        void* handle = openCompressionLibrary({ "libz.so.1", "libz.so" });
        if (!handle)
            return;
        library.version = lookupCompressionSymbol<ZlibVersionFn>(handle, "zlibVersion");
        library.deflate_init = lookupCompressionSymbol<ZlibDeflateInit2Fn>(handle, "deflateInit2_");
        library.deflate = lookupCompressionSymbol<ZlibDeflateFn>(handle, "deflate");
        library.deflate_end = lookupCompressionSymbol<ZlibDeflateEndFn>(handle, "deflateEnd");
        library.inflate_init = lookupCompressionSymbol<ZlibInflateInit2Fn>(handle, "inflateInit2_");
        library.inflate = lookupCompressionSymbol<ZlibInflateFn>(handle, "inflate");
        library.inflate_end = lookupCompressionSymbol<ZlibInflateEndFn>(handle, "inflateEnd");
        library.available = library.version && library.deflate_init && library.deflate && library.deflate_end
            && library.inflate_init && library.inflate && library.inflate_end;
    });
    return library;
}

const BrotliLibrary& sharedBrotliLibrary()
{
    static std::once_flag once;
    static BrotliLibrary library;
    std::call_once(once, [] {
        void* encoder_handle = openCompressionLibrary({ "libbrotlienc.so.1", "libbrotlienc.so" });
        void* decoder_handle = openCompressionLibrary({ "libbrotlidec.so.1", "libbrotlidec.so" });
        if (!encoder_handle || !decoder_handle)
            return;
        library.encoder_create
            = lookupCompressionSymbol<BrotliEncoderCreateFn>(encoder_handle, "BrotliEncoderCreateInstance");
        library.encoder_destroy
            = lookupCompressionSymbol<BrotliEncoderDestroyFn>(encoder_handle, "BrotliEncoderDestroyInstance");
        library.encoder_compress_stream
            = lookupCompressionSymbol<BrotliEncoderCompressStreamFn>(encoder_handle, "BrotliEncoderCompressStream");
        library.encoder_is_finished
            = lookupCompressionSymbol<BrotliEncoderIsFinishedFn>(encoder_handle, "BrotliEncoderIsFinished");
        library.decoder_create
            = lookupCompressionSymbol<BrotliDecoderCreateFn>(decoder_handle, "BrotliDecoderCreateInstance");
        library.decoder_destroy
            = lookupCompressionSymbol<BrotliDecoderDestroyFn>(decoder_handle, "BrotliDecoderDestroyInstance");
        library.decoder_decompress_stream
            = lookupCompressionSymbol<BrotliDecoderDecompressStreamFn>(decoder_handle, "BrotliDecoderDecompressStream");
        library.available = library.encoder_create && library.encoder_destroy && library.encoder_compress_stream
            && library.encoder_is_finished && library.decoder_create && library.decoder_destroy
            && library.decoder_decompress_stream;
    });
    return library;
}

void preloadCompressionLibraries()
{
    (void)sharedZlibLibrary();
    (void)sharedBrotliLibrary();
}

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

bool CompressionCodec::readableCanAcceptOutput(JSColloReadableStream* readable) const
{
    if (!readable)
        return false;
    if (readable->state() != StreamState::Readable)
        return false;
    return readable->hasPendingReadRequests() || readable->desiredSize() > 0;
}

CompressionProcessResult CompressionCodec::appendOutput(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStream* readable, std::span<const uint8_t> bytes, bool force)
{
    if (bytes.empty())
        return CompressionProcessResult::Complete;
    if (!force && !readableCanAcceptOutput(readable)) {
        // process() flushes held output before it runs the codec again, so a
        // second blocked output means that invariant broke.
        if (!m_pending_output.isEmpty()) {
            return CompressionProcessResult::Failed;
        }
        if (!m_pending_output.tryAppend(bytes)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return CompressionProcessResult::Failed;
        }
        return CompressionProcessResult::Blocked;
    }
    auto* chunk = createUint8ArrayCopy(global_object, scope, bytes);
    RETURN_IF_EXCEPTION(scope, CompressionProcessResult::Failed);
    readable->enqueue(global_object, scope, chunk);
    RETURN_IF_EXCEPTION(scope, CompressionProcessResult::Failed);
    return CompressionProcessResult::Complete;
}

CompressionProcessResult CompressionCodec::flushPendingOutput(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloReadableStream* readable)
{
    if (m_pending_output.isEmpty())
        return CompressionProcessResult::Complete;
    if (!readableCanAcceptOutput(readable))
        return CompressionProcessResult::Blocked;

    auto pending = std::span<const uint8_t> {
        m_pending_output.span().data(),
        m_pending_output.size(),
    };
    auto result = appendOutput(global_object, scope, readable, pending, true);
    if (result == CompressionProcessResult::Complete)
        m_pending_output.clear();
    return result;
}

CompressionProcessResult CompressionCodec::process(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size)
{
    remaining_input_size = input.size();
    auto pending_result = flushPendingOutput(global_object, scope, readable);
    if (pending_result != CompressionProcessResult::Complete)
        return pending_result;

    if (m_finished) {
        if (!input.empty()) {
            return CompressionProcessResult::Failed;
        }
        remaining_input_size = 0;
        return CompressionProcessResult::Complete;
    }
    if (!readableCanAcceptOutput(readable) && !input.empty()) {
        return CompressionProcessResult::Blocked;
    }
    if (m_finished && !input.empty())
        return CompressionProcessResult::Failed;
    if (m_kind == Kind::Zlib)
        return processZlib(global_object, scope, input, finish, readable, remaining_input_size);
    if (m_kind == Kind::Brotli)
        return processBrotli(global_object, scope, input, finish, readable, remaining_input_size);
    JSC::throwException(global_object, scope, JSC::createError(global_object, "compression codec is unavailable"_s));
    return CompressionProcessResult::Failed;
}

CompressionProcessResult CompressionCodec::processZlib(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size)
{
    if (input.size() > std::numeric_limits<unsigned int>::max()) {
        return CompressionProcessResult::Failed;
    }

    m_zlib_stream.next_in = input.empty() ? nullptr : input.data();
    m_zlib_stream.avail_in = static_cast<unsigned int>(input.size());
    const int flush = finish ? zlibFinish : zlibNoFlush;
    std::array<uint8_t, 16 * 1024> scratch;

    while (true) {
        m_zlib_stream.next_out = scratch.data();
        m_zlib_stream.avail_out = static_cast<unsigned int>(scratch.size());
        int status = m_decompressing ? m_zlib_library->inflate(&m_zlib_stream, flush)
                                     : m_zlib_library->deflate(&m_zlib_stream, flush);
        size_t produced = scratch.size() - m_zlib_stream.avail_out;
        if (produced) {
            const bool force = status == zlibStreamEnd;
            auto output_result = appendOutput(
                global_object, scope, readable, std::span<const uint8_t> { scratch.data(), produced }, force);
            if (output_result == CompressionProcessResult::Failed)
                return CompressionProcessResult::Failed;
            if (output_result == CompressionProcessResult::Blocked) {
                remaining_input_size = m_zlib_stream.avail_in;
                return CompressionProcessResult::Blocked;
            }
        }

        if (status == zlibStreamEnd) {
            if (m_decompressing && m_zlib_stream.avail_in != 0) {
                return CompressionProcessResult::Failed;
            }
            m_finished = true;
            remaining_input_size = 0;
            return CompressionProcessResult::Complete;
        }
        if (status == zlibMemoryError) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return CompressionProcessResult::Failed;
        }
        if (status == zlibDataError || status == zlibStreamError) {
            return CompressionProcessResult::Failed;
        }
        if (status == zlibBufferError) {
            // zlib returns Z_BUF_ERROR when it can make no progress. Every call
            // here gets the whole scratch buffer, so the input is the cause:
            // with finish requested the compressed data ended early, which
            // "decompress flush and enqueue" reports as a TypeError.
            if (finish)
                return CompressionProcessResult::Failed;
            // Without finish, only drained input is benign. Unconsumed input
            // means zlib is stuck, and claiming Complete would drop it.
            if (m_zlib_stream.avail_in != 0)
                return CompressionProcessResult::Failed;
            remaining_input_size = 0;
            return CompressionProcessResult::Complete;
        }
        if (status != zlibOk) {
            return CompressionProcessResult::Failed;
        }
        if (!finish && m_zlib_stream.avail_in == 0 && produced < scratch.size()) {
            remaining_input_size = 0;
            return CompressionProcessResult::Complete;
        }
    }
}

CompressionProcessResult CompressionCodec::processBrotli(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable, size_t& remaining_input_size)
{
    if (m_decompressing)
        return processBrotliDecoder(global_object, scope, input, finish, readable, remaining_input_size);
    return processBrotliEncoder(global_object, scope, input, finish, readable, remaining_input_size);
}

CompressionProcessResult CompressionCodec::processBrotliEncoder(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable,
    size_t& remaining_input_size)
{
    if (!m_brotli_library || !m_brotli_encoder_state)
        return CompressionProcessResult::Failed;

    const int operation = finish ? brotliEncoderOperationFinish : brotliEncoderOperationProcess;
    size_t available_in = input.size();
    const uint8_t* next_in = input.empty() ? nullptr : input.data();
    std::array<uint8_t, 16 * 1024> scratch;

    while (true) {
        size_t before_available_in = available_in;
        size_t available_out = scratch.size();
        uint8_t* next_out = scratch.data();
        int ok = m_brotli_library->encoder_compress_stream(
            m_brotli_encoder_state, operation, &available_in, &next_in, &available_out, &next_out, nullptr);
        if (!ok)
            return CompressionProcessResult::Failed;

        size_t produced = scratch.size() - available_out;
        const bool finished = finish && m_brotli_library->encoder_is_finished(m_brotli_encoder_state);
        if (produced) {
            auto output_result = appendOutput(
                global_object, scope, readable, std::span<const uint8_t> { scratch.data(), produced }, finished);
            if (output_result == CompressionProcessResult::Failed)
                return CompressionProcessResult::Failed;
            if (output_result == CompressionProcessResult::Blocked) {
                remaining_input_size = available_in;
                return CompressionProcessResult::Blocked;
            }
        }

        if (finished) {
            m_finished = true;
            remaining_input_size = 0;
            return CompressionProcessResult::Complete;
        }
        if (!finish && available_in == 0 && produced < scratch.size()) {
            remaining_input_size = 0;
            return CompressionProcessResult::Complete;
        }
        if (available_in == before_available_in && produced == 0) {
            return CompressionProcessResult::Failed;
        }
    }
}

CompressionProcessResult CompressionCodec::processBrotliDecoder(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, std::span<const uint8_t> input, bool finish, JSColloReadableStream* readable,
    size_t& remaining_input_size)
{
    if (!m_brotli_library || !m_brotli_decoder_state)
        return CompressionProcessResult::Failed;

    size_t available_in = input.size();
    const uint8_t* next_in = input.empty() ? nullptr : input.data();
    std::array<uint8_t, 16 * 1024> scratch;

    while (true) {
        size_t available_out = scratch.size();
        uint8_t* next_out = scratch.data();
        int status = m_brotli_library->decoder_decompress_stream(
            m_brotli_decoder_state, &available_in, &next_in, &available_out, &next_out, nullptr);
        size_t produced = scratch.size() - available_out;
        if (produced) {
            const bool force = status == brotliDecoderResultSuccess;
            auto output_result = appendOutput(
                global_object, scope, readable, std::span<const uint8_t> { scratch.data(), produced }, force);
            if (output_result == CompressionProcessResult::Failed)
                return CompressionProcessResult::Failed;
            if (output_result == CompressionProcessResult::Blocked) {
                remaining_input_size = available_in;
                return CompressionProcessResult::Blocked;
            }
        }

        switch (status) {
        case brotliDecoderResultError:
            return CompressionProcessResult::Failed;
        case brotliDecoderResultSuccess:
            if (available_in != 0)
                return CompressionProcessResult::Failed;
            m_finished = true;
            remaining_input_size = 0;
            return CompressionProcessResult::Complete;
        case brotliDecoderResultNeedsMoreInput:
            if (finish || available_in != 0)
                return CompressionProcessResult::Failed;
            remaining_input_size = 0;
            return CompressionProcessResult::Complete;
        case brotliDecoderResultNeedsMoreOutput:
            if (produced == 0)
                return CompressionProcessResult::Failed;
            continue;
        default:
            return CompressionProcessResult::Failed;
        }
    }
}

static JSColloCompressionStream* compressionStreamFromFunction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
{
    JSValue value = function->get(global_object, compressionStreamStateIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* stream = dynamicDowncast<JSColloCompressionStream>(value);
    if (!stream)
        JSC::throwVMTypeError(global_object, scope, "CompressionStream state is unavailable"_s);
    return stream;
}

struct CompressionInputBytes {
    std::span<const uint8_t> bytes;
};

static bool compressionInputBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, CompressionInputBytes& out)
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
    return JSValue::encode(JSC::jsUndefined());
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
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(compressionCancelCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = compressionStreamFromFunction(
        global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    stream->readableCanceled(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    compressionChunkSizeCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSValue chunk = call_frame->argument(0);
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(chunk)) {
        if (arrayBufferViewIsUnavailable(view))
            return JSValue::encode(JSC::jsNumber(0));
        return JSValue::encode(JSC::jsNumber(view->byteLength()));
    }
    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(chunk)) {
        if (arrayBufferIsUnavailableForCopy(array_buffer))
            return JSValue::encode(JSC::jsNumber(0));
        return JSValue::encode(JSC::jsNumber(arrayBufferBytes(array_buffer).size()));
    }
    auto string = chunk.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsNumber(string.length()));
}

static JSValue createCompressionCallback(JSC::JSGlobalObject* global_object, JSColloCompressionStream* stream,
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
    if (!m_codec.init(format, decompressing)) {
        JSC::throwException(
            global_object, scope, JSC::createTypeError(global_object, "requested compression format is unavailable"_s));
        return false;
    }

    m_decompressing = decompressing;
    auto* readable = JSColloReadableStream::create(vm, collo_global);
    auto* readable_controller = JSColloReadableStreamDefaultController::create(vm, global_object, readable);
    readable->setController(vm, readable_controller);
    // The Compression standard sets up its TransformStream with the default
    // high-water marks, 0 for the readable side and 1 for the writable side
    // below, so a write stays pending until the readable side pulls.
    readable->setHighWaterMark(0);
    JSValue pull_function
        = createCompressionCallback(global_object, this, "CompressionStream pull"_s, compressionPullCallback, 0);
    JSValue cancel_function
        = createCompressionCallback(global_object, this, "CompressionStream cancel"_s, compressionCancelCallback, 1);
    JSValue size_function
        = createCompressionCallback(global_object, this, "CompressionStream size"_s, compressionChunkSizeCallback, 1);
    readable_controller->setCallbacks(vm, pull_function, cancel_function, size_function);
    m_readable.set(vm, this, readable);

    JSValue write_function
        = createCompressionCallback(global_object, this, "CompressionStream write"_s, compressionWriteCallback, 1);
    JSValue close_function
        = createCompressionCallback(global_object, this, "CompressionStream close"_s, compressionCloseCallback, 0);
    JSValue abort_function
        = createCompressionCallback(global_object, this, "CompressionStream abort"_s, compressionAbortCallback, 1);
    auto* writable = createWritableStreamFromCallbacks(global_object, scope, JSC::jsUndefined(), write_function,
        close_function, abort_function, JSC::jsUndefined(), 1);
    RETURN_IF_EXCEPTION(scope, false);
    if (!writable)
        return false;
    m_writable.set(vm, this, writable);
    return true;
}

void JSColloCompressionStream::clearPendingOperation()
{
    if (m_pending_deferred) {
        collo_promise_deferred_release(m_pending_deferred);
        m_pending_deferred = nullptr;
    }
    m_pending_promise.clear();
    m_pending_input.clear();
    m_pending_offset = 0;
    m_pending_operation = PendingOperation::None;
}

bool JSColloCompressionStream::setPendingOperation(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    PendingOperation operation, std::span<const uint8_t> bytes)
{
    if (m_pending_operation != PendingOperation::None) {
        JSC::throwVMTypeError(global_object, scope, "CompressionStream already has a pending operation"_s);
        return false;
    }

    JSValue promise;
    ColloPromiseDeferred* deferred = nullptr;
    if (!createDeferredPromise(global_object, scope, promise, deferred))
        return false;

    m_pending_promise.set(global_object->vm(), this, promise);
    m_pending_deferred = deferred;
    m_pending_operation = operation;
    m_pending_offset = 0;
    m_pending_input.clear();
    if (!bytes.empty() && !m_pending_input.tryAppend(bytes)) {
        clearPendingOperation();
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    return true;
}

CompressionProcessResult JSColloCompressionStream::pumpPendingOperation(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (m_pending_operation == PendingOperation::None)
        return CompressionProcessResult::Complete;
    auto* readable_stream = readable();
    if (!readable_stream) {
        JSC::throwVMTypeError(global_object, scope, "CompressionStream readable side is unavailable"_s);
        return CompressionProcessResult::Failed;
    }

    const bool finish = m_pending_operation == PendingOperation::Close;
    auto input = std::span<const uint8_t> {};
    if (m_pending_offset < m_pending_input.size()) {
        input = std::span<const uint8_t> {
            m_pending_input.span().data() + m_pending_offset,
            m_pending_input.size() - m_pending_offset,
        };
    }

    size_t remaining_input_size = input.size();
    auto result = m_codec.process(global_object, scope, input, finish, readable_stream, remaining_input_size);
    if (result == CompressionProcessResult::Blocked) {
        const size_t consumed = input.size() - remaining_input_size;
        m_pending_offset += consumed;
        if (m_pending_offset > m_pending_input.size())
            m_pending_offset = m_pending_input.size();
        return CompressionProcessResult::Blocked;
    }
    if (result == CompressionProcessResult::Failed)
        return CompressionProcessResult::Failed;

    m_pending_offset = m_pending_input.size();
    return CompressionProcessResult::Complete;
}

void JSColloCompressionStream::resolvePendingOperation(JSC::JSGlobalObject* global_object)
{
    PendingOperation operation = m_pending_operation;
    auto* deferred = m_pending_deferred;
    m_pending_deferred = nullptr;
    m_pending_promise.clear();
    m_pending_input.clear();
    m_pending_offset = 0;
    m_pending_operation = PendingOperation::None;

    if (operation == PendingOperation::Close) {
        if (auto* readable_stream = readable())
            readable_stream->close(global_object);
    }
    settleDeferred(global_object, deferred, JSC::jsUndefined(), false);
}

void JSColloCompressionStream::rejectPendingOperation(JSC::JSGlobalObject* global_object, JSValue reason)
{
    if (auto* promise = dynamicDowncast<JSC::JSPromise>(m_pending_promise.get()))
        promise->markAsHandled();
    auto* deferred = m_pending_deferred;
    m_pending_deferred = nullptr;
    m_pending_promise.clear();
    m_pending_input.clear();
    m_pending_offset = 0;
    m_pending_operation = PendingOperation::None;
    settleDeferred(global_object, deferred, reason, true);
}

void JSColloCompressionStream::failBothSides(JSC::JSGlobalObject* global_object, JSValue reason)
{
    if (auto* readable_stream = readable())
        readable_stream->error(global_object, reason);
    m_codec.deinit();
    rejectPendingOperation(global_object, reason);
}

EncodedJSValue JSColloCompressionStream::drivePendingOperation(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    JSValue promise = m_pending_promise.get();
    auto result = pumpPendingOperation(global_object, scope);
    if (scope.exception()) {
        JSValue reason = scope.exception()->value();
        if (!scope.tryClearException()) {
            m_codec.deinit();
            rejectPendingOperation(global_object, reason);
            return {};
        }
        failBothSides(global_object, reason);
        JSC::throwException(global_object, scope, reason);
        return {};
    }
    if (result == CompressionProcessResult::Failed) {
        // The Compression standard reports every codec error as a TypeError.
        JSValue error = JSC::createTypeError(global_object, "compression stream failed"_s);
        failBothSides(global_object, error);
        return JSValue::encode(promise);
    }
    if (result == CompressionProcessResult::Complete)
        resolvePendingOperation(global_object);
    return JSValue::encode(promise);
}

EncodedJSValue JSColloCompressionStream::write(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
{
    CompressionInputBytes input;
    if (!compressionInputBytes(global_object, scope, chunk, input))
        return {};
    if (!setPendingOperation(global_object, scope, PendingOperation::Write, input.bytes))
        return {};
    return drivePendingOperation(global_object, scope);
}

EncodedJSValue JSColloCompressionStream::close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!setPendingOperation(global_object, scope, PendingOperation::Close, {}))
        return {};
    return drivePendingOperation(global_object, scope);
}

void JSColloCompressionStream::resume(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (m_pending_operation == PendingOperation::None)
        return;
    (void)drivePendingOperation(global_object, scope);
}

void JSColloCompressionStream::readableCanceled(JSC::JSGlobalObject* global_object, JSValue reason)
{
    const bool had_pending = m_pending_operation != PendingOperation::None;
    m_codec.deinit();
    // A pending write or close errors the writable side when its rejected
    // promise reaches the writable stream; with none pending, it is errored
    // here.
    rejectPendingOperation(global_object, reason);
    if (!had_pending) {
        if (auto* writable_stream = writable())
            writable_stream->error(global_object, reason);
    }
}

void JSColloCompressionStream::abort(JSC::JSGlobalObject* global_object, JSValue reason)
{
    if (auto* readable_stream = readable())
        readable_stream->error(global_object, reason);
    m_codec.deinit();
    rejectPendingOperation(global_object, reason);
}
// CompressionStream and DecompressionStream share one cell class, so the
// direction tells a receiver of one from an instance of the other.
static JSColloCompressionStream* requireCompressionStreamInstance(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, JSValue value, bool expected_decompression, WTF::ASCIILiteral class_name)
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
    return JSValue::encode(stream);
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
    return JSValue::encode(stream);
}

JSC_DEFINE_HOST_FUNCTION(
    compressionStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = requireCompressionStreamInstance(global_object, scope, call_frame->thisValue(), false, "CompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream->readable());
}

JSC_DEFINE_HOST_FUNCTION(
    compressionStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = requireCompressionStreamInstance(global_object, scope, call_frame->thisValue(), false, "CompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream->writable());
}

JSC_DEFINE_HOST_FUNCTION(
    decompressionStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireCompressionStreamInstance(
        global_object, scope, call_frame->thisValue(), true, "DecompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream->readable());
}

JSC_DEFINE_HOST_FUNCTION(
    decompressionStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireCompressionStreamInstance(
        global_object, scope, call_frame->thisValue(), true, "DecompressionStream"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream->writable());
}
} // namespace Collo::HostFunctions
