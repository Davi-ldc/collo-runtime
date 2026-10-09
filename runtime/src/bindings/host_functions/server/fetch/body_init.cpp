// Extraction of a BodyInit for the Request and Response constructors. Runs on the VM thread. A Blob or FormData body
// shares its storage, a ReadableStream becomes a stream body, a buffer source is copied, and any other value becomes
// its string. Every body except a stream is checked against WebApiMaterializedBodyBytesMax, a buffer source before
// it is copied, and an oversized body throws a QuotaExceededError DOMException.

#include "host_functions/server/fetch/body.h"
#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/files/formdata.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/readable_stream_private.h"

#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <wtf/Vector.h>

namespace Collo::HostFunctions {
namespace {

    static JSC::JSObject* createBodyQuotaExceeded(JSC::JSGlobalObject* global_object)
    {
        return createDOMException(
            global_object, DOMExceptionCode::QuotaExceededError, "Body exceeds the serverless body limit"_s);
    }

    static bool ensureBodyMaterializationBudget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t byte_size)
    {
        if (byte_size <= WebApiMaterializedBodyBytesMax)
            return true;
        JSC::throwException(global_object, scope, createBodyQuotaExceeded(global_object));
        return false;
    }

} // namespace

bool createBodyStateFromJS(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue body_value, BodyInitResult& out)
{
    out.body = PendingBody {};
    out.content_type = WTF::emptyString();

    if (body_value.isUndefinedOrNull())
        return true;

    if (auto* blob = dynamicDowncast<JSColloBlob>(body_value)) {
        if (!ensureBodyMaterializationBudget(global_object, scope, blob->size()))
            return false;
        out.body.state = BodyState::fromSharedBytes(blob->storageRef(), blob->byteOffset(), blob->size());
        out.content_type = blob->type();
        return true;
    }

    if (isColloFormData(body_value)) {
        // The multipart serialization shares each File or Blob part's bytes, so the body becomes a SharedBytes body
        // over storage that adds only the part headers, the text values and the framing, and formData() reads it back
        // through the multipart parser.
        size_t size = 0;
        WTF::String content_type;
        auto storage = serializeFormDataToMultipartBody(global_object, scope, body_value, size, content_type);
        RETURN_IF_EXCEPTION(scope, false);
        if (!storage)
            return false;
        if (!ensureBodyMaterializationBudget(global_object, scope, size))
            return false;
        out.body.state = BodyState::fromSharedBytes(storage.releaseNonNull(), 0, size);
        out.content_type = WTF::move(content_type);
        return true;
    }

    if (auto* stream = readableStreamFromValue(body_value)) {
        out.body = PendingBody::fromStream(stream);
        return true;
    }

    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(body_value)) {
        if (!validateArrayBufferViewForCopy(
                global_object, scope, view, "BodyInit ArrayBufferView is detached or out of bounds"_s))
            return false;
        if (!ensureBodyMaterializationBudget(global_object, scope, view->byteLength()))
            return false;
        WTF::Vector<uint8_t> bytes;
        if (!copyBytes(global_object, scope, bytes, arrayBufferViewBytes(view)))
            return false;
        if (!BodyState::fromBytes(WTF::move(bytes), out.body.state)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        return true;
    }

    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(body_value)) {
        if (!validateArrayBufferForCopy(
                global_object, scope, array_buffer, "BodyInit must be a fixed-length attached ArrayBuffer"_s))
            return false;
        auto source_bytes = arrayBufferBytes(array_buffer);
        if (!ensureBodyMaterializationBudget(global_object, scope, source_bytes.size()))
            return false;
        WTF::Vector<uint8_t> bytes;
        if (!copyBytes(global_object, scope, bytes, source_bytes))
            return false;
        if (!BodyState::fromBytes(WTF::move(bytes), out.body.state)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        return true;
    }

    auto body_text = valueToWebApiString(global_object, scope, body_value);
    RETURN_IF_EXCEPTION(scope, false);
    size_t body_text_bytes = 0;
    if (!stringUtf8ByteLength(body_text, body_text_bytes)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    if (!ensureBodyMaterializationBudget(global_object, scope, body_text_bytes))
        return false;
    out.body.state = BodyState::fromText(WTF::move(body_text));
    return true;
}

} // namespace Collo::HostFunctions
