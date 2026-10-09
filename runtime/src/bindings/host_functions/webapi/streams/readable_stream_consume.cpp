// Body consumption of a ReadableStream. A stream backed by a native source that can drain in one step is read that
// way; any other stream is read to the end through its reader, buffering at most WebApiMaterializedBodyBytesMax bytes
// before converting them. Runs on the VM thread. A consumption that reads through a reader roots the reader and its
// result promise until it settles or its request ends; ReadableStreamBodyConsumerState says why request end must cut
// those roots.

#include "host_functions/webapi/streams/readable_stream_consume.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/encoding/utf8.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/files/formdata.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/readable_stream_private.h"

#include <JavaScriptCore/JSONObject.h>

namespace Collo::HostFunctions {
namespace {

    constexpr size_t ReadableStreamBodyConsumerMaxBytes = WebApiMaterializedBodyBytesMax;

    JSC::JSObject* createReadableStreamBodyQuotaExceeded(JSC::JSGlobalObject* global_object)
    {
        return createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
            "ReadableStream body exceeds the serverless body limit"_s);
    }

    bool ensureReadableStreamBodyBudget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t current_size, size_t chunk_size)
    {
        const size_t remaining
            = ReadableStreamBodyConsumerMaxBytes - std::min(current_size, ReadableStreamBodyConsumerMaxBytes);
        if (chunk_size <= remaining)
            return true;
        JSC::throwException(global_object, scope, createReadableStreamBodyQuotaExceeded(global_object));
        return false;
    }

    bool appendReadableStreamChunkBytes(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<uint8_t>& output, JSValue chunk)
    {
        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(chunk)) {
            if (!validateArrayBufferViewForCopy(global_object, scope, view,
                    "ReadableStream body chunk ArrayBufferView is detached or out of bounds"_s))
                return false;
            if (!ensureReadableStreamBodyBudget(global_object, scope, output.size(), view->byteLength()))
                return false;
            return copyBytes(global_object, scope, output, arrayBufferViewBytes(view));
        }

        if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(chunk)) {
            if (!validateArrayBufferForCopy(global_object, scope, array_buffer,
                    "ReadableStream body chunk must be a fixed-length attached ArrayBuffer"_s))
                return false;
            auto bytes = arrayBufferBytes(array_buffer);
            if (!ensureReadableStreamBodyBudget(global_object, scope, output.size(), bytes.size()))
                return false;
            return copyBytes(global_object, scope, output, bytes);
        }

        if (chunk.isString()) {
            auto text = chunk.toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, false);
            if (output.size() > ReadableStreamBodyConsumerMaxBytes
                || !stringUtf8LengthWithinLimit(text, ReadableStreamBodyConsumerMaxBytes - output.size())) {
                JSC::throwException(global_object, scope, createReadableStreamBodyQuotaExceeded(global_object));
                return false;
            }
            return appendStringBytes(global_object, scope, output, text);
        }

        JSC::throwVMTypeError(global_object, scope, "ReadableStream body chunks must be bytes"_s);
        return false;
    }

    // Holds the reader and the result promise in Strong handles until the consumption settles, and is itself kept
    // alive only by the Ref its read reactions capture. The collector cannot break that cycle (see
    // ColloRequestScopedRoots in jsc/runtime/state.h), so the state registers with the VM and the end of its request
    // drops the roots.
    class ReadableStreamBodyConsumerState final : public WTF::RefCounted<ReadableStreamBodyConsumerState>,
                                                  public ColloRequestScopedRoots {
    public:
        static WTF::RefPtr<ReadableStreamBodyConsumerState> create(JSC::JSGlobalObject* global_object,
            JSC::JSObject* reader, JSC::JSPromise* promise, ReadableStreamBodyConsumer consumer,
            WTF::String content_type)
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(ReadableStreamBodyConsumerState)).getValue(storage))
                return nullptr;
            auto& owner = uncheckedDowncast<Collo::GlobalObject>(global_object)->owner();
            auto* state = new (NotNull, storage) ReadableStreamBodyConsumerState(
                global_object->vm(), reader, promise, consumer, WTF::move(content_type));
            // The owner is the request activeExecContext resolves to; ColloRequestScopedRoots::owner_request_id in
            // jsc/runtime/state.h says when each kind of owner, including 0, gets cleared.
            auto* exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(owner);
            state->registerRequestScopedRoots(owner.request_scoped_roots, exec_ctx ? exec_ctx->request_id : 0);
            return adoptRef(*state);
        }

        ~ReadableStreamBodyConsumerState()
        {
            m_reader.clear();
            m_promise.clear();
        }

        // The request is over, so its JavaScript can no longer observe the promise or read from the reader, and the
        // state drops its roots and goes inert. Settling the promise instead would queue a microtask after the
        // response has finished.
        void clearRequestScopedRoots() final
        {
            m_settled = true;
            clear();
        }

        template <typename Scope> bool scheduleRead(JSC::JSGlobalObject* global_object, Scope& scope)
        {
            auto* reader = dynamicDowncast<JSC::JSObject>(m_reader.get());
            if (!reader) {
                reject(global_object, JSC::createTypeError(global_object, "ReadableStream reader is unavailable"_s));
                return true;
            }

            auto read = reader->get(global_object, JSC::Identifier::fromString(global_object->vm(), "read"_s));
            RETURN_IF_EXCEPTION(scope, false);
            if (!bodyValueIsCallable(read)) {
                reject(global_object, JSC::createTypeError(global_object, "ReadableStream reader is not readable"_s));
                return true;
            }

            JSC::MarkedArgumentBuffer arguments;
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            auto call_data = JSC::getCallData(read);
            auto read_result = JSC::call(global_object, read.getObject(), call_data, reader, arguments);
            RETURN_IF_EXCEPTION(scope, false);

            auto* promise = dynamicDowncast<JSC::JSPromise>(read_result);
            if (!promise)
                return handleReadResult(global_object, scope, read_result);

            auto protected_this = Ref { *this };
            auto* fulfilled = JSC::JSNativeStdFunction::create(global_object->vm(), global_object, 1,
                "ReadableStream body read fulfilled"_s,
                [protected_this](JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame) mutable {
                    auto& vm = global_object->vm();
                    auto scope = DECLARE_THROW_SCOPE(vm);
                    protected_this->handleReadResult(global_object, scope, call_frame->argument(0));
                    if (scope.exception()) {
                        auto exception = scope.exception()->value();
                        if (scope.tryClearException())
                            protected_this->reject(global_object, exception);
                    }
                    return JSValue::encode(JSC::jsUndefined());
                });
            auto* rejected = JSC::JSNativeStdFunction::create(global_object->vm(), global_object, 1,
                "ReadableStream body read rejected"_s,
                [protected_this](JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame) mutable {
                    protected_this->reject(global_object, call_frame->argument(0));
                    return JSValue::encode(JSC::jsUndefined());
                });
            promise->performPromiseThen(global_object->vm(), global_object, fulfilled, rejected, JSC::jsUndefined());
            RETURN_IF_EXCEPTION(scope, false);
            return true;
        }

    private:
        ReadableStreamBodyConsumerState(JSC::VM& vm, JSC::JSObject* reader, JSC::JSPromise* promise,
            ReadableStreamBodyConsumer consumer, WTF::String content_type)
            : m_reader(vm, reader)
            , m_promise(vm, promise)
            , m_consumer(consumer)
            , m_content_type(WTF::move(content_type))
        {
        }

        template <typename Scope>
        bool handleReadResult(JSC::JSGlobalObject* global_object, Scope& scope, JSValue result)
        {
            if (m_settled)
                return true;
            auto* object = result.getObject();
            if (!object) {
                reject(
                    global_object, JSC::createTypeError(global_object, "ReadableStream read returned a non-object"_s));
                return true;
            }

            auto done_value = object->get(global_object, global_object->vm().propertyNames->done);
            RETURN_IF_EXCEPTION(scope, false);
            bool done = done_value.toBoolean(global_object);
            RETURN_IF_EXCEPTION(scope, false);
            if (done) {
                resolveFinal(global_object, scope);
                return !scope.exception();
            }

            auto chunk = object->get(global_object, global_object->vm().propertyNames->value);
            RETURN_IF_EXCEPTION(scope, false);
            if (!appendReadableStreamChunkBytes(global_object, scope, m_bytes, chunk))
                return false;
            RETURN_IF_EXCEPTION(scope, false);
            return scheduleRead(global_object, scope);
        }

        template <typename Scope>
        void rejectPendingException(JSC::JSGlobalObject* global_object, Scope& scope, JSValue fallback)
        {
            JSValue exception = scope.exception() ? scope.exception()->value() : JSValue {};
            if (!scope.tryClearException())
                return;
            if (!exception)
                exception = fallback;
            reject(global_object, exception);
        }

        template <typename Scope> void resolveFinal(JSC::JSGlobalObject* global_object, Scope& scope)
        {
            releaseReader(global_object);
            JSValue value;
            switch (m_consumer) {
            case ReadableStreamBodyConsumer::Text:
                value = JSC::jsString(global_object->vm(), decodeUtf8Bytes(m_bytes.span()));
                break;
            case ReadableStreamBodyConsumer::Json:
                value = JSC::JSONParse(global_object, decodeUtf8Bytes(m_bytes.span()));
                if (scope.exception()) {
                    rejectPendingException(
                        global_object, scope, JSC::createSyntaxError(global_object, "Invalid JSON"_s));
                    return;
                }
                if (!value) {
                    reject(global_object, JSC::createSyntaxError(global_object, "Invalid JSON"_s));
                    return;
                }
                break;
            case ReadableStreamBodyConsumer::ArrayBuffer:
                value = createArrayBufferCopy(global_object, scope, m_bytes.span());
                if (scope.exception()) {
                    rejectPendingException(global_object, scope, JSC::createOutOfMemoryError(global_object));
                    return;
                }
                break;
            case ReadableStreamBodyConsumer::Bytes:
                value = createBodyUint8ArrayCopy(global_object, scope, m_bytes.span());
                if (scope.exception()) {
                    rejectPendingException(global_object, scope, JSC::createOutOfMemoryError(global_object));
                    return;
                }
                break;
            case ReadableStreamBodyConsumer::Blob: {
                WTF::Vector<uint8_t> bytes;
                if (!copyBytes(global_object, scope, bytes, m_bytes.span())) {
                    rejectPendingException(global_object, scope, JSC::createOutOfMemoryError(global_object));
                    return;
                }
                value = createBodyBlob(global_object, scope, WTF::move(bytes), WTF::move(m_content_type));
                if (scope.exception()) {
                    rejectPendingException(global_object, scope, JSC::createOutOfMemoryError(global_object));
                    return;
                }
                break;
            }
            case ReadableStreamBodyConsumer::FormData: {
                WTF::ASCIILiteral parse_error = "Invalid form data"_s;
                value = createFormDataFromBodyBytes(
                    global_object, scope, m_bytes.span(), WTF::move(m_content_type), &parse_error);
                if (scope.exception()) {
                    rejectPendingException(global_object, scope, JSC::createOutOfMemoryError(global_object));
                    return;
                }
                if (!value) {
                    if (isFormDataQuotaParseError(parse_error))
                        value = createDOMException(
                            global_object, DOMExceptionCode::QuotaExceededError, WTF::String(parse_error));
                    else
                        value = JSC::createTypeError(global_object, parse_error);
                    reject(global_object, value);
                    return;
                }
                break;
            }
            }
            if (!value) {
                reject(global_object, JSC::createOutOfMemoryError(global_object));
                return;
            }
            resolve(global_object, value);
        }

        void resolve(JSC::JSGlobalObject* global_object, JSValue value)
        {
            if (m_settled)
                return;
            m_settled = true;
            if (auto* promise = dynamicDowncast<JSC::JSPromise>(m_promise.get()))
                promise->resolve(global_object, global_object->vm(), value);
            clear();
        }

        void reject(JSC::JSGlobalObject* global_object, JSValue reason)
        {
            if (m_settled)
                return;
            m_settled = true;
            releaseReader(global_object);
            if (auto* promise = dynamicDowncast<JSC::JSPromise>(m_promise.get()))
                promise->reject(global_object->vm(), reason);
            clear();
        }

        void releaseReader(JSC::JSGlobalObject* global_object)
        {
            auto* reader = dynamicDowncast<JSC::JSObject>(m_reader.get());
            releaseReadableStreamReader(global_object, reader);
        }

        // Detaching here, before the destructor would, keeps the registry to consumptions still outstanding: once the
        // roots are gone there is no cycle left for request end to cut.
        void clear()
        {
            detachRequestScopedRoots();
            m_reader.clear();
            m_promise.clear();
            m_bytes.clear();
        }

        JSC::Strong<JSC::Unknown> m_reader;
        JSC::Strong<JSC::Unknown> m_promise;
        WTF::Vector<uint8_t> m_bytes;
        ReadableStreamBodyConsumer m_consumer;
        WTF::String m_content_type;
        bool m_settled { false };
    };

    JSC::EncodedJSValue consumeReadableStreamBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::JSObject* stream, ReadableStreamBodyConsumer consumer, WTF::String content_type)
    {
        if (!stream)
            return rejectedTypeError(global_object, scope, "ReadableStream body is unavailable"_s);
        if (readableStreamIsDisturbed(stream))
            return rejectedTypeError(global_object, scope, "ReadableStream body is already used"_s);
        if (readableStreamIsLocked(stream))
            return rejectedTypeError(global_object, scope, "ReadableStream is locked"_s);

        auto& vm = global_object->vm();
        auto* promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
        auto reject_promise = [&](JSValue reason) -> JSC::EncodedJSValue {
            if (!reason)
                reason = JSC::createTypeError(global_object, "ReadableStream body read failed"_s);
            promise->reject(vm, reason);
            return JSValue::encode(promise);
        };

        auto get_reader = stream->get(global_object, JSC::Identifier::fromString(vm, "getReader"_s));
        if (scope.exception()) {
            auto exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            return reject_promise(exception);
        }
        if (!bodyValueIsCallable(get_reader))
            return reject_promise(JSC::createTypeError(global_object, "ReadableStream body is not readable"_s));

        JSC::MarkedArgumentBuffer arguments;
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto call_data = JSC::getCallData(get_reader);
        auto reader_value = JSC::call(global_object, get_reader.getObject(), call_data, stream, arguments);
        if (scope.exception()) {
            auto exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            return reject_promise(exception);
        }
        auto* reader = dynamicDowncast<JSC::JSObject>(reader_value);
        if (!reader)
            return reject_promise(JSC::createTypeError(global_object, "ReadableStream body reader is unavailable"_s));

        auto state = ReadableStreamBodyConsumerState::create(
            global_object, reader, promise, consumer, WTF::move(content_type));
        if (!state) {
            releaseReadableStreamReader(global_object, reader);
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        if (!state->scheduleRead(global_object, scope)) {
            JSValue read_error;
            if (scope.exception()) {
                read_error = scope.exception()->value();
                if (!scope.tryClearException())
                    return {};
            }
            releaseReadableStreamReader(global_object, reader);
            return reject_promise(read_error);
        }
        if (scope.exception()) {
            auto exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            return reject_promise(exception);
        }
        return JSValue::encode(promise);
    }

    JSC::EncodedJSValue resolveDrainedReadableStreamBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        ReadableStreamBodyConsumer consumer, WTF::Vector<uint8_t>&& bytes, WTF::String content_type)
    {
        switch (consumer) {
        case ReadableStreamBodyConsumer::Text:
            if (!ensureDecodedStringSize(global_object, scope, bytes.size()))
                return {};
            return resolvedPromise(global_object, JSC::jsString(global_object->vm(), decodeUtf8Bytes(bytes.span())));
        case ReadableStreamBodyConsumer::Json:
            if (!ensureDecodedStringSize(global_object, scope, bytes.size()))
                return {};
            return parseBodyJsonTextToPromise(global_object, decodeUtf8Bytes(bytes.span()));
        case ReadableStreamBodyConsumer::ArrayBuffer: {
            auto storage = ColloSharedBytes::create(WTF::move(bytes));
            if (!storage) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            const size_t byte_length = storage->size();
            auto owned_storage = storage.releaseNonNull();
            auto* value = createArrayBufferFromExclusiveSharedBytes(
                global_object, scope, WTF::move(owned_storage), 0, byte_length);
            RETURN_IF_EXCEPTION(scope, {});
            if (value)
                return resolvedPromise(global_object, value);
            return {};
        }
        case ReadableStreamBodyConsumer::Bytes: {
            auto storage = ColloSharedBytes::create(WTF::move(bytes));
            if (!storage) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            const size_t byte_length = storage->size();
            auto owned_storage = storage.releaseNonNull();
            auto* value = createUint8ArrayFromExclusiveSharedBytes(
                global_object, scope, WTF::move(owned_storage), 0, byte_length);
            RETURN_IF_EXCEPTION(scope, {});
            if (value)
                return resolvedPromise(global_object, value);
            return {};
        }
        case ReadableStreamBodyConsumer::Blob:
            if (auto* blob = createBodyBlob(global_object, scope, WTF::move(bytes), WTF::move(content_type)))
                return resolvedPromise(global_object, blob);
            return {};
        case ReadableStreamBodyConsumer::FormData:
            return parseBodyFormDataBytesToPromise(global_object, scope, bytes.span(), WTF::move(content_type));
        }
        return {};
    }

} // namespace

JSC::EncodedJSValue consumeReadableStreamBodyWithNativeFastPath(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, JSC::JSObject* stream, ReadableStreamBodyConsumer consumer, WTF::String content_type)
{
    if (!stream)
        return rejectedTypeError(global_object, scope, "ReadableStream body is unavailable"_s);
    if (readableStreamIsDisturbed(stream))
        return rejectedTypeError(global_object, scope, "ReadableStream body is already used"_s);
    if (readableStreamIsLocked(stream))
        return rejectedTypeError(global_object, scope, "ReadableStream is locked"_s);

    WTF::Vector<uint8_t> bytes;
    switch (readableStreamDrainNativeBytes(global_object, stream, bytes, ReadableStreamBodyConsumerMaxBytes)) {
    case ReadableStreamDrainResult::Drained:
        return resolveDrainedReadableStreamBody(
            global_object, scope, consumer, WTF::move(bytes), WTF::move(content_type));
    case ReadableStreamDrainResult::OutOfMemory:
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    case ReadableStreamDrainResult::TooLarge:
        return rejectedPromise(global_object, scope, createReadableStreamBodyQuotaExceeded(global_object));
    case ReadableStreamDrainResult::NotAvailable:
        return consumeReadableStreamBody(global_object, scope, stream, consumer, WTF::move(content_type));
    }
    return {};
}

} // namespace Collo::HostFunctions
