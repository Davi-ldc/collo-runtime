// The synchronous `Crypto` methods: `getRandomValues`, `randomUUID`, and `timingSafeEqual`, which is not part of the
// Web Cryptography API. They run on the VM thread and throw on failure. Random bytes come from the receiver's entropy
// cache (`JSColloCrypto::fillRandom`), keyed by the VM's current process id so a worker never serves bytes drawn in
// the zygote.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/sync/methods.h"

#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/TypedArrayType.h>
#include <openssl/crypto.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;
using namespace Collo::JscSupport;

static JSColloCrypto* requireCrypto(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* crypto = dynamicDowncast<JSColloCrypto>(value))
        return crypto;
    JSC::throwVMTypeError(global_object, scope, "Crypto method called on incompatible receiver"_s);
    return nullptr;
}

static bool isIntegerTypedArray(JSC::TypedArrayType type)
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

static JSC::JSObject* createCryptoDOMException(JSC::JSGlobalObject* global_object, DOMExceptionCode code)
{
    return createDOMException(global_object, code);
}

// `collo_vm_post_fork_child` rewrites the VM's process id after a fork, so the value changes exactly when the process
// does.
static uint64_t currentProcessId(JSC::JSGlobalObject* global_object)
{
    return uncheckedDowncast<Collo::GlobalObject>(global_object)->owner().process_id_at_creation;
}

JSC_DEFINE_HOST_FUNCTION(cryptoGetRandomValues, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* crypto = requireCrypto(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});

    auto value = call_frame->argument(0);
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value);
    if (!view || !isIntegerTypedArray(JSC::typedArrayType(view->type()))) {
        auto* exception = createCryptoDOMException(global_object, DOMExceptionCode::TypeMismatchError);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    if (view->isDetached() || view->isOutOfBounds())
        return JSC::throwVMTypeError(
            global_object, scope, "Crypto.getRandomValues requires an attached integer TypedArray"_s);

    // The Web Cryptography API's getRandomValues steps set this cap and its QuotaExceededError.
    auto byte_length = view->byteLength();
    if (byte_length > 65536) {
        auto* exception = createCryptoDOMException(global_object, DOMExceptionCode::QuotaExceededError);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    if (!crypto->fillRandom(currentProcessId(global_object),
            std::span<uint8_t> { static_cast<uint8_t*>(view->vector()), byte_length })) {
        auto* exception = createCryptoDOMException(global_object, DOMExceptionCode::OperationError);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
    }
    return JSC::JSValue::encode(value);
}

static void formatUuidV4(std::span<const uint8_t, 16> bytes, std::span<Latin1Character, 36> output)
{
    static constexpr std::array<Latin1Character, 512> hex_pairs = [] {
        std::array<Latin1Character, 512> pairs {};
        constexpr std::array<Latin1Character, 16> hex {
            '0',
            '1',
            '2',
            '3',
            '4',
            '5',
            '6',
            '7',
            '8',
            '9',
            'a',
            'b',
            'c',
            'd',
            'e',
            'f',
        };
        for (unsigned value = 0; value < 256; ++value) {
            pairs[value * 2] = hex[value >> 4];
            pairs[value * 2 + 1] = hex[value & 0x0f];
        }
        return pairs;
    }();

    auto writeByte = [&](unsigned offset, uint8_t byte) {
        output[offset] = hex_pairs[byte * 2];
        output[offset + 1] = hex_pairs[byte * 2 + 1];
    };

    writeByte(0, bytes[0]);
    writeByte(2, bytes[1]);
    writeByte(4, bytes[2]);
    writeByte(6, bytes[3]);
    output[8] = '-';
    writeByte(9, bytes[4]);
    writeByte(11, bytes[5]);
    output[13] = '-';
    writeByte(14, bytes[6]);
    writeByte(16, bytes[7]);
    output[18] = '-';
    writeByte(19, bytes[8]);
    writeByte(21, bytes[9]);
    output[23] = '-';
    writeByte(24, bytes[10]);
    writeByte(26, bytes[11]);
    writeByte(28, bytes[12]);
    writeByte(30, bytes[13]);
    writeByte(32, bytes[14]);
    writeByte(34, bytes[15]);
}

JSC_DEFINE_HOST_FUNCTION(cryptoRandomUUID, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* crypto = requireCrypto(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});

    std::array<uint8_t, 16> bytes;
    if (!crypto->fillRandom(currentProcessId(global_object), bytes)) {
        auto* exception = createCryptoDOMException(global_object, DOMExceptionCode::OperationError);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
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

    std::span<const uint8_t> left;
    std::span<const uint8_t> right;
    JSValue error;
    if (!borrowBufferSource(global_object, call_frame->argument(0), left, error))
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, error));
    if (!borrowBufferSource(global_object, call_frame->argument(1), right, error))
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, error));

    if (left.size() != right.size())
        return JSC::JSValue::encode(JSC::throwException(global_object, scope,
            JSC::createRangeError(global_object, "Input buffers must have the same byte length"_s)));

    bool equal = left.empty() || CRYPTO_memcmp(left.data(), right.data(), left.size()) == 0;
    return JSC::JSValue::encode(JSC::jsBoolean(equal));
}

} // namespace Collo::HostFunctions::WebCrypto
