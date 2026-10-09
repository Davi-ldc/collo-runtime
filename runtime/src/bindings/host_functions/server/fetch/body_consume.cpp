// The Body mixin's consumers for every BodyState source, each returning a promise. Runs on the VM thread. A used body
// rejects with the caller's already-used message as a TypeError. An empty body stays unused: text(), arrayBuffer(),
// bytes() and blob() resolve with the empty value, json() rejects with a SyntaxError as parsing empty text does, and
// formData() rejects with a TypeError. Zig reads a lazy request body or a fetch stream and settles the promise later.
// A body too long to decode and an allocation failure throw into the scope instead.

#include "host_functions/server/fetch/body.h"
#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/runtime/fetch_body.h"
#include "host_functions/runtime/request_body.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/streams/readable_stream_consume.h"
#include "host_functions/webapi/streams/stream_common_private.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/Vector.h>

#include <span>

namespace Collo::HostFunctions {
namespace {

    using JSC::JSValue;

    static JSC::JSValue makeByteConsumerValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        BodyByteConsumer consumer, WTF::String text, WTF::String blob_type)
    {
        WTF::Vector<uint8_t> bytes;
        if (!appendStringBytes(global_object, scope, bytes, text))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        switch (consumer) {
        case BodyByteConsumer::ArrayBuffer:
            return createArrayBufferCopy(global_object, scope, bytes.span());
        case BodyByteConsumer::Bytes:
            return createBodyUint8ArrayCopy(global_object, scope, bytes.span());
        case BodyByteConsumer::Blob:
            return createBodyBlob(global_object, scope, WTF::move(bytes), WTF::move(blob_type));
        }
        return {};
    }

    static JSC::EncodedJSValue resolveByteConsumer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        BodyByteConsumer consumer, WTF::String text, WTF::String blob_type)
    {
        auto value = makeByteConsumerValue(global_object, scope, consumer, WTF::move(text), WTF::move(blob_type));
        RETURN_IF_EXCEPTION(scope, {});
        return resolvedPromise(global_object, value);
    }

    static JSC::EncodedJSValue resolveRawByteConsumer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        BodyByteConsumer consumer, std::span<const uint8_t> bytes, WTF::String blob_type)
    {
        switch (consumer) {
        case BodyByteConsumer::ArrayBuffer:
            if (auto* value = createArrayBufferCopy(global_object, scope, bytes))
                return resolvedPromise(global_object, value);
            return {};
        case BodyByteConsumer::Bytes:
            if (auto* value = createBodyUint8ArrayCopy(global_object, scope, bytes))
                return resolvedPromise(global_object, value);
            return {};
        case BodyByteConsumer::Blob: {
            WTF::Vector<uint8_t> copied;
            if (!copyBytes(global_object, scope, copied, bytes))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            auto* blob = createBodyBlob(global_object, scope, WTF::move(copied), WTF::move(blob_type));
            RETURN_IF_EXCEPTION(scope, {});
            return resolvedPromise(global_object, blob);
        }
        }
        return {};
    }

    static JSC::EncodedJSValue resolveOwnedByteConsumer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        BodyByteConsumer consumer, WTF::RefPtr<ColloSharedBytes>& bytes, WTF::String blob_type)
    {
        if (!bytes) {
            return resolveRawByteConsumer(
                global_object, scope, consumer, std::span<const uint8_t> {}, WTF::move(blob_type));
        }
        // Adopting the buffer, or taking its vector for a Blob, needs the sole reference: script can write an
        // ArrayBuffer's bytes, and taking the vector empties the buffer for every other reader. A buffer that a clone
        // or an extracted response still reads is copied.
        if (!bytes->hasOneRef())
            return resolveRawByteConsumer(global_object, scope, consumer, bytes->span(), WTF::move(blob_type));

        const size_t byte_length = bytes->size();
        switch (consumer) {
        case BodyByteConsumer::ArrayBuffer: {
            auto storage = bytes.releaseNonNull();
            if (auto* value
                = createArrayBufferFromExclusiveSharedBytes(global_object, scope, WTF::move(storage), 0, byte_length))
                return resolvedPromise(global_object, value);
            return {};
        }
        case BodyByteConsumer::Bytes: {
            auto storage = bytes.releaseNonNull();
            if (auto* value
                = createUint8ArrayFromExclusiveSharedBytes(global_object, scope, WTF::move(storage), 0, byte_length))
                return resolvedPromise(global_object, value);
            return {};
        }
        case BodyByteConsumer::Blob: {
            auto storage = bytes.releaseNonNull();
            auto moved_bytes = storage->takeVectorForExclusiveUse();
            auto* blob = createBodyBlob(global_object, scope, WTF::move(moved_bytes), WTF::move(blob_type));
            RETURN_IF_EXCEPTION(scope, {});
            if (blob)
                return resolvedPromise(global_object, blob);
            return {};
        }
        }
        return {};
    }

    static JSC::EncodedJSValue resolveSharedByteConsumer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        BodyByteConsumer consumer, const BlobStorage& storage, size_t offset, size_t size)
    {
        switch (consumer) {
        case BodyByteConsumer::ArrayBuffer:
            if (auto* value = createArrayBufferCopy(global_object, scope, storage, offset, size))
                return resolvedPromise(global_object, value);
            return {};
        case BodyByteConsumer::Bytes:
            if (auto* value = createBodyUint8ArrayCopy(global_object, scope, storage, offset, size))
                return resolvedPromise(global_object, value);
            return {};
        case BodyByteConsumer::Blob:
            // consumeBlob builds the Blob over the shared storage itself and never asks for one here.
            break;
        }
        return {};
    }

} // namespace
JSC::EncodedJSValue BodyState::consumeText(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* stream, WTF::ASCIILiteral already_used_message)
{
    if (m_source == Source::Empty) {
        if (m_used)
            return rejectedAlreadyUsedTypeError(global_object, already_used_message);
        return resolvedPromise(global_object, JSC::jsEmptyString(global_object->vm()));
    }

    JSC::EncodedJSValue rejection {};
    if (!markUsed(global_object, stream, already_used_message, rejection))
        return rejection;

    switch (m_source) {
    case Source::Empty:
        break;
    case Source::Text:
        // text() decodes the body's UTF-8 bytes, and that decode drops a leading BOM, so a text body drops a leading
        // U+FEFF too.
        return resolvedPromise(global_object, JSC::jsString(global_object->vm(), stripLeadingUtf8Bom(m_text)));
    case Source::Bytes:
        if (!ensureDecodedStringSize(global_object, scope, sharedBytesSpan(m_bytes).size()))
            return {};
        return resolvedPromise(
            global_object, JSC::jsString(global_object->vm(), decodeUtf8Bytes(sharedBytesSpan(m_bytes))));
    case Source::SharedBytes: {
        if (!ensureDecodedStringSize(global_object, scope, m_shared_size))
            return {};
        WTF::Vector<uint8_t> bytes;
        if (!appendSharedBytes(global_object, scope, bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return resolvedPromise(global_object, JSC::jsString(global_object->vm(), decodeUtf8Bytes(bytes.span())));
    }
    case Source::RequestLazy:
        return requestTextForIdentity(global_object, scope, m_identity);
    case Source::FetchStream:
        return fetchBodyTextForIdentity(global_object, scope, m_fetch_body_identity);
    case Source::ReadableStream:
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Text, {});
    }
    return rejectedAlreadyUsedTypeError(global_object, already_used_message);
}

JSC::EncodedJSValue BodyState::consumeJson(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* stream, WTF::ASCIILiteral already_used_message)
{
    if (m_source == Source::Empty) {
        if (m_used)
            return rejectedAlreadyUsedTypeError(global_object, already_used_message);
        return parseBodyJsonTextToPromise(global_object, WTF::emptyString());
    }

    JSC::EncodedJSValue rejection {};
    if (!markUsed(global_object, stream, already_used_message, rejection))
        return rejection;

    switch (m_source) {
    case Source::Empty:
        break;
    case Source::Text:
        return parseBodyJsonTextToPromise(global_object, m_text);
    case Source::Bytes:
        if (!ensureDecodedStringSize(global_object, scope, sharedBytesSpan(m_bytes).size()))
            return {};
        return parseBodyJsonTextToPromise(global_object, decodeUtf8Bytes(sharedBytesSpan(m_bytes)));
    case Source::SharedBytes: {
        if (!ensureDecodedStringSize(global_object, scope, m_shared_size))
            return {};
        WTF::Vector<uint8_t> bytes;
        if (!appendSharedBytes(global_object, scope, bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return parseBodyJsonTextToPromise(global_object, decodeUtf8Bytes(bytes.span()));
    }
    case Source::RequestLazy:
        return requestJsonForIdentity(global_object, scope, m_identity);
    case Source::FetchStream:
        return fetchBodyJsonForIdentity(global_object, scope, m_fetch_body_identity);
    case Source::ReadableStream:
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Json, {});
    }
    return rejectedAlreadyUsedTypeError(global_object, already_used_message);
}

JSC::EncodedJSValue BodyState::consumeArrayBuffer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* stream, WTF::ASCIILiteral already_used_message)
{
    if (m_source == Source::Empty) {
        if (m_used)
            return rejectedAlreadyUsedTypeError(global_object, already_used_message);
        return resolveByteConsumer(
            global_object, scope, BodyByteConsumer::ArrayBuffer, WTF::emptyString(), WTF::emptyString());
    }

    JSC::EncodedJSValue rejection {};
    if (!markUsed(global_object, stream, already_used_message, rejection))
        return rejection;

    switch (m_source) {
    case Source::Empty:
        break;
    case Source::Text:
        return resolveByteConsumer(global_object, scope, BodyByteConsumer::ArrayBuffer, m_text, WTF::emptyString());
    case Source::Bytes:
        return resolveOwnedByteConsumer(
            global_object, scope, BodyByteConsumer::ArrayBuffer, m_bytes, WTF::emptyString());
    case Source::SharedBytes:
        return resolveSharedByteConsumer(
            global_object, scope, BodyByteConsumer::ArrayBuffer, *m_shared_storage, m_shared_offset, m_shared_size);
    case Source::RequestLazy:
        return requestArrayBufferForIdentity(global_object, scope, m_identity);
    case Source::FetchStream:
        return fetchBodyArrayBufferForIdentity(global_object, scope, m_fetch_body_identity);
    case Source::ReadableStream:
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::ArrayBuffer, {});
    }
    return rejectedAlreadyUsedTypeError(global_object, already_used_message);
}

JSC::EncodedJSValue BodyState::consumeBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* stream, WTF::ASCIILiteral already_used_message)
{
    if (m_source == Source::Empty) {
        if (m_used)
            return rejectedAlreadyUsedTypeError(global_object, already_used_message);
        return resolveByteConsumer(
            global_object, scope, BodyByteConsumer::Bytes, WTF::emptyString(), WTF::emptyString());
    }

    JSC::EncodedJSValue rejection {};
    if (!markUsed(global_object, stream, already_used_message, rejection))
        return rejection;

    switch (m_source) {
    case Source::Empty:
        break;
    case Source::Text:
        return resolveByteConsumer(global_object, scope, BodyByteConsumer::Bytes, m_text, WTF::emptyString());
    case Source::Bytes:
        return resolveOwnedByteConsumer(global_object, scope, BodyByteConsumer::Bytes, m_bytes, WTF::emptyString());
    case Source::SharedBytes:
        return resolveSharedByteConsumer(
            global_object, scope, BodyByteConsumer::Bytes, *m_shared_storage, m_shared_offset, m_shared_size);
    case Source::RequestLazy:
        return requestBytesForIdentity(global_object, scope, m_identity);
    case Source::FetchStream:
        return fetchBodyBytesForIdentity(global_object, scope, m_fetch_body_identity);
    case Source::ReadableStream:
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Bytes, {});
    }
    return rejectedAlreadyUsedTypeError(global_object, already_used_message);
}

JSC::EncodedJSValue BodyState::consumeBlob(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* stream, WTF::ASCIILiteral already_used_message, WTF::String type)
{
    if (m_source == Source::Empty) {
        if (m_used)
            return rejectedAlreadyUsedTypeError(global_object, already_used_message);
        return resolveByteConsumer(global_object, scope, BodyByteConsumer::Blob, WTF::emptyString(), WTF::move(type));
    }

    JSC::EncodedJSValue rejection {};
    if (!markUsed(global_object, stream, already_used_message, rejection))
        return rejection;

    switch (m_source) {
    case Source::Empty:
        break;
    case Source::Text:
        return resolveByteConsumer(global_object, scope, BodyByteConsumer::Blob, m_text, WTF::move(type));
    case Source::Bytes:
        return resolveOwnedByteConsumer(global_object, scope, BodyByteConsumer::Blob, m_bytes, WTF::move(type));
    case Source::SharedBytes: {
        return resolvedPromise(global_object,
            JSColloBlob::create(global_object->vm(),
                uncheckedDowncast<Collo::GlobalObject>(global_object)->blobStructure(),
                WTF::Ref<BlobStorage> { *m_shared_storage }, m_shared_offset, m_shared_size,
                normalizeBlobType(WTF::move(type))));
    }
    case Source::RequestLazy:
        return requestBlobForIdentity(global_object, scope, m_identity, WTF::move(type));
    case Source::FetchStream:
        return fetchBodyBlobForIdentity(global_object, scope, m_fetch_body_identity, WTF::move(type));
    case Source::ReadableStream:
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Blob, WTF::move(type));
    }
    return rejectedAlreadyUsedTypeError(global_object, already_used_message);
}

JSC::EncodedJSValue BodyState::consumeFormData(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* stream, WTF::ASCIILiteral already_used_message, WTF::String content_type)
{
    if (m_source == Source::Empty) {
        if (m_used)
            return rejectedAlreadyUsedTypeError(global_object, already_used_message);
        return rejectedTypeError(global_object, scope, "Body.formData requires a non-null body"_s);
    }

    JSC::EncodedJSValue rejection {};
    if (!markUsed(global_object, stream, already_used_message, rejection))
        return rejection;

    switch (m_source) {
    case Source::Empty:
        break;
    case Source::Text:
        return parseBodyFormDataTextToPromise(global_object, scope, m_text, WTF::move(content_type));
    case Source::Bytes:
        return parseBodyFormDataBytesToPromise(global_object, scope, sharedBytesSpan(m_bytes), WTF::move(content_type));
    case Source::SharedBytes: {
        WTF::Vector<uint8_t> bytes;
        if (!appendSharedBytes(global_object, scope, bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return parseBodyFormDataBytesToPromise(global_object, scope, bytes.span(), WTF::move(content_type));
    }
    case Source::RequestLazy:
        return requestFormDataForIdentity(global_object, scope, m_identity, WTF::move(content_type));
    case Source::FetchStream:
        return fetchBodyFormDataForIdentity(global_object, scope, m_fetch_body_identity, WTF::move(content_type));
    case Source::ReadableStream:
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::FormData, WTF::move(content_type));
    }
    return rejectedAlreadyUsedTypeError(global_object, already_used_message);
}

} // namespace Collo::HostFunctions
