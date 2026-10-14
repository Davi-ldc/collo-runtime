// Body consumption of a ReadableStream. A stream backed by a native source that can drain in one step is read that
// way; any other stream is read to the end by a JSColloBodyConsumer through the stream's own read, buffering at most
// WebApiMaterializedBodyBytesMax bytes before converting them. Runs on the VM thread.
//
// The consumer is a cell: it holds the stream, its reader and the result promise in WriteBarrier fields, and the
// pending read's reaction is the one thing that holds the consumer. Nothing roots any of it, so a consumption whose
// stream nobody can feed is ordinary garbage the collector reclaims, with no request-end cleanup; the bytes it buffered
// are reported as its memory, so they count toward the next collection. Chunks already queued are taken in the same
// call, one read each; a read still pending resumes the loop from its reaction. The result promise settles with the
// converted body itself, or with the reason the conversion refused it.
//
// Fetch's "fully read body" gets a reader for the stream and never releases it, so a consumed stream stays locked
// whether the consumption succeeded or failed: the consumer forgets its reader without releasing it, and the one-step
// path locks the stream with a reader of its own.

#include "host_functions/webapi/streams/readable_stream_consume.h"

#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/files/formdata.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/readable_stream_private.h"

#include <JavaScriptCore/JSONObject.h>

namespace Collo::HostFunctions {
namespace {

    JSC::JSObject* createBodyTooLargeError(JSC::JSGlobalObject* global_object)
    {
        return createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
            "ReadableStream body exceeds the materialized body limit"_s);
    }

    // The body's bytes converted as `consumer` says, as Fetch's "consume body" converts them: on true, `out.value` is
    // what the Body method fulfills with, or, with `out.rejected` set, what it rejects with (the SyntaxError of text
    // that is not JSON, or what the form data parser refused). Returns false with the exception pending when memory
    // runs out or a termination is pending.
    struct BodyValue {
        JSC::JSValue value;
        bool rejected { false };
    };

    bool convertBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ReadableStreamBodyConsumer consumer,
        WTF::Vector<uint8_t>&& bytes, WTF::String content_type, BodyValue& out)
    {
        auto& vm = global_object->vm();
        out = {};
        switch (consumer) {
        case ReadableStreamBodyConsumer::Text: {
            WTF::String text;
            if (!decodeUtf8Bytes(global_object, scope, bytes.span(), text))
                return false;
            out.value = JSC::jsString(vm, WTF::move(text));
            return true;
        }
        case ReadableStreamBodyConsumer::Json: {
            // "Parse JSON from bytes": the UTF-8 decode drops one leading BOM, and JSON.parse sees the rest.
            WTF::String text;
            if (!decodeUtf8Bytes(global_object, scope, bytes.span(), text))
                return false;
            JSC::JSValue parsed = JSC::JSONParse(global_object, text);
            if (auto* exception = scope.exception()) {
                JSC::JSValue reason = exception->value();
                if (!scope.tryClearException())
                    return false;
                out.value = reason;
                out.rejected = true;
                return true;
            }
            if (!parsed) {
                out.value = JSC::createSyntaxError(global_object, "Invalid JSON"_s);
                out.rejected = true;
                return true;
            }
            out.value = parsed;
            return true;
        }
        case ReadableStreamBodyConsumer::ArrayBuffer:
        case ReadableStreamBodyConsumer::Bytes: {
            auto storage = ColloSharedBytes::create(WTF::move(bytes));
            if (!storage) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            const size_t byte_length = storage->size();
            if (consumer == ReadableStreamBodyConsumer::ArrayBuffer)
                out.value = createArrayBufferFromExclusiveSharedBytes(
                    global_object, scope, storage.releaseNonNull(), 0, byte_length);
            else
                out.value = createUint8ArrayFromExclusiveSharedBytes(
                    global_object, scope, storage.releaseNonNull(), 0, byte_length);
            RETURN_IF_EXCEPTION(scope, false);
            return true;
        }
        case ReadableStreamBodyConsumer::Blob:
            out.value = createBodyBlob(global_object, scope, WTF::move(bytes), WTF::move(content_type));
            RETURN_IF_EXCEPTION(scope, false);
            return true;
        case ReadableStreamBodyConsumer::FormData: {
            WTF::ASCIILiteral parse_error = "Invalid form data"_s;
            auto* form_data = createFormDataFromBodyBytes(
                global_object, scope, bytes.span(), WTF::move(content_type), &parse_error);
            RETURN_IF_EXCEPTION(scope, false);
            if (form_data) {
                out.value = form_data;
                return true;
            }
            out.value = isFormDataQuotaParseError(parse_error)
                ? createDOMException(global_object, DOMExceptionCode::QuotaExceededError, WTF::String(parse_error))
                : JSC::createTypeError(global_object, parse_error);
            out.rejected = true;
            return true;
        }
        }
        ASSERT_NOT_REACHED();
        JSC::throwVMTypeError(global_object, scope, "ReadableStream body consumer is not supported"_s);
        return false;
    }

    // Locks the stream with a reader nothing ever releases. Returns null when a termination is pending.
    JSColloReadableStreamDefaultReader* lockForBody(
        JSC::VM& vm, Collo::GlobalObject* global_object, JSColloReadableStream* stream)
    {
        auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
        if (reader)
            stream->lock(vm, reader);
        return reader;
    }

} // namespace

JSColloBodyConsumer* JSColloBodyConsumer::create(JSC::VM& vm, Collo::GlobalObject* global_object,
    JSColloReadableStream* stream, JSC::JSPromise* promise, ReadableStreamBodyConsumer kind, WTF::String content_type)
{
    auto* reader = lockForBody(vm, global_object, stream);
    if (!reader)
        return nullptr;
    auto* consumer = new (NotNull, JSC::allocateCell<JSColloBodyConsumer>(vm))
        JSColloBodyConsumer(vm, global_object->bodyConsumerStructure(), kind, WTF::move(content_type));
    consumer->finishCreation(vm, stream, reader, promise);
    return consumer;
}

void JSColloBodyConsumer::finishCreation(
    JSC::VM& vm, JSColloReadableStream* stream, JSColloReadableStreamDefaultReader* reader, JSC::JSPromise* promise)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_stream.set(vm, this, stream);
    m_reader.set(vm, this, reader);
    m_promise.set(vm, this, promise);
}

void JSColloBodyConsumer::readNext(JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    while (m_promise.get()) {
        auto* stream = m_stream.get();
        if (!stream)
            return;
        auto scope = DECLARE_THROW_SCOPE(vm);
        JSC::JSValue read_value = JSC::JSValue::decode(stream->read(global_object, scope));
        if (scope.exception()) {
            JSC::JSValue exception = scope.exception()->value();
            if (!scope.tryClearException())
                return;
            reject(global_object, exception);
            return;
        }
        auto* read_promise = dynamicDowncast<JSC::JSPromise>(read_value);
        if (!read_promise) {
            reject(global_object, JSC::createTypeError(global_object, "ReadableStream read failed"_s));
            return;
        }
        // A chunk already queued arrives in a promise fulfilled at once, which is taken here instead of a microtask
        // later. A pending or rejected read goes through the reaction, which also marks a rejection handled.
        if (read_promise->status() != JSC::JSPromise::Status::Fulfilled) {
            reactToPromise(global_object, read_promise, StreamReaction::BodyConsumerRead, this);
            return;
        }
        if (!takeReadResult(global_object, read_promise->result()))
            return;
    }
}

void JSColloBodyConsumer::readFulfilled(JSC::JSGlobalObject* global_object, JSC::JSValue result)
{
    if (takeReadResult(global_object, result))
        readNext(global_object);
}

void JSColloBodyConsumer::readRejected(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    reject(global_object, reason);
}

bool JSColloBodyConsumer::takeReadResult(JSC::JSGlobalObject* global_object, JSC::JSValue result)
{
    if (!m_promise.get())
        return false;
    auto& vm = global_object->vm();
    bool done = false;
    JSC::JSValue error;
    if (!readResultDone(global_object, result, done, error)) {
        reject(global_object, error);
        return false;
    }
    if (done) {
        resolveWithBytes(global_object);
        return false;
    }
    auto scope = DECLARE_THROW_SCOPE(vm);
    std::span<const uint8_t> bytes;
    if (!readableStreamChunkBytes(global_object, scope, readResultValue(global_object, result), bytes)) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return false;
        reject(global_object, exception);
        return false;
    }
    if (bytes.size() > WebApiMaterializedBodyBytesMax - std::min(m_bytes.size(), WebApiMaterializedBodyBytesMax)) {
        reject(global_object, createBodyTooLargeError(global_object));
        return false;
    }
    if (!m_bytes.tryAppend(bytes)) {
        reject(global_object, JSC::createOutOfMemoryError(global_object));
        return false;
    }
    noteBufferedBytes();
    return true;
}

void JSColloBodyConsumer::forgetStream()
{
    m_reader.clear();
    m_stream.clear();
}

void JSColloBodyConsumer::noteBufferedBytes()
{
    const size_t cost = m_bytes.capacity();
    m_bytes_cost.store(cost, std::memory_order_relaxed);
    if (cost <= m_bytes_cost_reported)
        return;
    const size_t growth = cost - m_bytes_cost_reported;
    m_bytes_cost_reported = cost;
    vm().heap.reportExtraMemoryAllocated(this, growth);
}

// Fetch's "fully read body" settles the Body method's promise with the converted value itself, so no promise sits in
// between to delay it by further microtask turns.
void JSColloBodyConsumer::resolveWithBytes(JSC::JSGlobalObject* global_object)
{
    forgetStream();
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    BodyValue body_value;
    const bool converted = convertBody(global_object, scope, m_kind, WTF::move(m_bytes), m_content_type, body_value);
    m_bytes = {};
    noteBufferedBytes();
    if (!converted) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        settleAndClearPromise(global_object, m_promise, exception, true);
        return;
    }
    settleAndClearPromise(global_object, m_promise, body_value.value, body_value.rejected);
}

void JSColloBodyConsumer::reject(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    forgetStream();
    m_bytes = {};
    noteBufferedBytes();
    settleAndClearPromise(global_object, m_promise, reason, true);
}

JSC::EncodedJSValue consumeReadableStreamBodyWithNativeFastPath(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, JSC::JSObject* stream_object, ReadableStreamBodyConsumer consumer, WTF::String content_type)
{
    auto* stream = dynamicDowncast<JSColloReadableStream>(stream_object);
    if (!stream)
        return rejectedTypeError(global_object, scope, "ReadableStream body is unavailable"_s);
    if (stream->disturbed())
        return rejectedTypeError(global_object, scope, "ReadableStream body is already used"_s);
    if (stream->locked())
        return rejectedTypeError(global_object, scope, "ReadableStream is locked"_s);

    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    WTF::Vector<uint8_t> bytes;
    const auto drain_result = stream->drainNativeBytes(bytes, WebApiMaterializedBodyBytesMax);
    if (drain_result != ReadableStreamDrainResult::NotAvailable && !lockForBody(vm, collo_global, stream))
        return {};
    switch (drain_result) {
    case ReadableStreamDrainResult::Drained: {
        BodyValue body_value;
        if (!convertBody(global_object, scope, consumer, WTF::move(bytes), WTF::move(content_type), body_value))
            return {};
        if (body_value.rejected)
            return rejectedPromise(global_object, scope, body_value.value);
        return resolvedPromise(global_object, body_value.value);
    }
    case ReadableStreamDrainResult::OutOfMemory:
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    case ReadableStreamDrainResult::TooLarge:
        return rejectedPromise(global_object, scope, createBodyTooLargeError(global_object));
    case ReadableStreamDrainResult::NotAvailable:
        break;
    }

    auto* promise = Collo::newPromise(global_object);
    auto* consumer_cell
        = JSColloBodyConsumer::create(vm, collo_global, stream, promise, consumer, WTF::move(content_type));
    RETURN_IF_EXCEPTION(scope, {});
    if (!consumer_cell)
        return {};
    consumer_cell->readNext(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

} // namespace Collo::HostFunctions
