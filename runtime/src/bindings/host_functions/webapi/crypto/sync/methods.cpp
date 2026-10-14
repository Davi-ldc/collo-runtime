// The synchronous `Crypto` methods: `getRandomValues`, `randomUUID`, and `timingSafeEqual`, which is not part of the
// Web Cryptography API. They run on the VM thread and throw on failure. Random bytes come from BoringSSL's RAND_bytes
// on every call; its generator keeps its own per-thread state and reseeds after a fork, so a worker never repeats bytes
// drawn in the zygote, and the Crypto object holds no state of its own.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/sync/methods.h"

#include "host_functions/webapi/crypto/objects.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/TypedArrayType.h>
#include <openssl/crypto.h>
#include <openssl/rand.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

using Collo::JscSupport::throwDOMException;
using JSC::JSValue;

namespace {

    // The getRandomValues steps of the Web Cryptography API set this cap and its QuotaExceededError.
    constexpr size_t random_values_bytes_max = 65536;

    void requireCrypto(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (!dynamicDowncast<JSColloCrypto>(value))
            JSC::throwTypeError(global_object, scope, "Crypto method called on incompatible receiver"_s);
    }

    bool isIntegerTypedArray(JSC::TypedArrayType type)
    {
        switch (type) {
        case JSC::TypeInt8:
        case JSC::TypeUint8:
        case JSC::TypeUint8Clamped:
        case JSC::TypeInt16:
        case JSC::TypeUint16:
        case JSC::TypeInt32:
        case JSC::TypeUint32:
        case JSC::TypeBigInt64:
        case JSC::TypeBigUint64:
            return true;
        case JSC::NotTypedArray:
        case JSC::TypeFloat16:
        case JSC::TypeFloat32:
        case JSC::TypeFloat64:
        case JSC::TypeDataView:
            return false;
        }
        return false;
    }

    bool fillRandom(std::span<uint8_t> bytes) { return bytes.empty() || RAND_bytes(bytes.data(), bytes.size()) == 1; }

    void formatUuidV4(std::span<const uint8_t, 16> bytes, std::span<Latin1Character, 36> output)
    {
        constexpr std::array<Latin1Character, 16> hex { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c',
            'd', 'e', 'f' };
        size_t out = 0;
        for (size_t index = 0; index < bytes.size(); ++index) {
            // The dashes of the 8-4-4-4-12 form precede bytes 4, 6, 8 and 10.
            if (index == 4 || index == 6 || index == 8 || index == 10)
                output[out++] = '-';
            output[out++] = hex[bytes[index] >> 4];
            output[out++] = hex[bytes[index] & 0x0f];
        }
    }

} // namespace

JSC_DEFINE_HOST_FUNCTION(cryptoGetRandomValues, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    requireCrypto(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});

    JSValue value = call_frame->argument(0);
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value);
    if (!view || !isIntegerTypedArray(JSC::typedArrayType(view->type()))) {
        throwDOMException(global_object, scope, DOMExceptionCode::TypeMismatchError);
        return {};
    }
    if (view->isDetached() || view->isOutOfBounds())
        return JSC::throwVMTypeError(
            global_object, scope, "Crypto.getRandomValues requires an attached integer TypedArray"_s);
    const size_t byte_length = view->byteLength();
    if (byte_length > random_values_bytes_max) {
        throwDOMException(global_object, scope, DOMExceptionCode::QuotaExceededError);
        return {};
    }
    if (!fillRandom(std::span<uint8_t> { static_cast<uint8_t*>(view->vector()), byte_length })) {
        throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
        return {};
    }
    return JSC::JSValue::encode(value);
}

JSC_DEFINE_HOST_FUNCTION(cryptoRandomUUID, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    requireCrypto(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});

    std::array<uint8_t, 16> bytes;
    if (!fillRandom(bytes)) {
        throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
        return {};
    }
    // The randomUUID steps of the Web Cryptography API: version 4 in the top four bits of byte 6, variant 10 in the
    // top two bits of byte 8.
    bytes[6] = static_cast<uint8_t>((bytes[6] & 0x0f) | 0x40);
    bytes[8] = static_cast<uint8_t>((bytes[8] & 0x3f) | 0x80);

    std::span<Latin1Character> output;
    auto uuid = WTF::String::createUninitialized(36, output);
    formatUuidV4(std::span<const uint8_t, 16> { bytes }, std::span<Latin1Character, 36> { output.data(), 36 });
    return JSC::JSValue::encode(JSC::jsString(vm, uuid));
}

JSC_DEFINE_HOST_FUNCTION(cryptoTimingSafeEqual, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    requireCrypto(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (call_frame->argumentCount() < 2)
        return JSC::throwVMTypeError(
            global_object, scope, "Crypto.timingSafeEqual requires two BufferSource arguments"_s);

    auto left = Collo::JscSupport::borrowBufferSource(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    auto right = Collo::JscSupport::borrowBufferSource(global_object, scope, call_frame->argument(1));
    RETURN_IF_EXCEPTION(scope, {});
    if (left->size() != right->size()) {
        return JSC::JSValue::encode(JSC::throwException(global_object, scope,
            JSC::createRangeError(global_object, "Input buffers must have the same byte length"_s)));
    }
    const bool equal = left->empty() || CRYPTO_memcmp(left->data(), right->data(), left->size()) == 0;
    return JSC::JSValue::encode(JSC::jsBoolean(equal));
}

} // namespace Collo::HostFunctions::WebCrypto
