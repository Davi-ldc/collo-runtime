// Argument conversions declared in normalize.h, on the VM thread. Every property read and every conversion of a script
// value can run a getter or `valueOf` that throws, so each one is followed by an exception check before anything else
// runs. The helpers share the caller's ThrowScope and return no value once an exception is pending.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/normalize.h"

#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <limits>

namespace Collo::HostFunctions::WebCrypto {

using Collo::JscSupport::throwDOMException;
using JSC::JSValue;
using WTF::String;

namespace {

    // The member `name` of `object`, or undefined when `object` is null, as for an algorithm given as a string.
    JSValue member(JSC::JSGlobalObject* global_object, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        if (!object)
            return JSC::jsUndefined();
        return object->get(global_object, JSC::Identifier::fromString(global_object->vm(), name));
    }

    // An algorithm's name: the string itself, or the `name` member of an object. Sets `out_object` to the object, or
    // null for a string.
    String algorithmName(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, JSC::JSObject*& out_object)
    {
        out_object = nullptr;
        if (value.isString())
            return value.toWTFString(global_object);
        auto* object = dynamicDowncast<JSC::JSObject>(value);
        if (!object) {
            JSC::throwTypeError(global_object, scope, "Algorithm must be a string or object"_s);
            return {};
        }
        JSValue name = member(global_object, object, "name"_s);
        RETURN_IF_EXCEPTION(scope, {});
        if (name.isUndefined()) {
            JSC::throwTypeError(global_object, scope, "Algorithm name is required"_s);
            return {};
        }
        out_object = object;
        return name.toWTFString(global_object);
    }

    std::optional<WTF::Vector<uint8_t>> requiredBufferSource(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        JSValue value = member(global_object, object, name);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (value.isUndefined()) {
            JSC::throwTypeError(global_object, scope,
                WTF::makeString(
                    "Member "_s, name, " is required and must be an instance of (ArrayBufferView or ArrayBuffer)"_s));
            return std::nullopt;
        }
        return Collo::JscSupport::copyBufferSource(global_object, scope, value);
    }

    // An absent member is an empty copy.
    std::optional<WTF::Vector<uint8_t>> optionalBufferSource(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        JSValue value = member(global_object, object, name);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (value.isUndefined())
            return WTF::Vector<uint8_t> {};
        return Collo::JscSupport::copyBufferSource(global_object, scope, value);
    }

    // A required `unsigned long`, whose value outside [0, 2^32 - 1] is a TypeError.
    std::optional<uint32_t> requiredUnsignedLong(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        JSValue value = member(global_object, object, name);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (value.isUndefined()) {
            JSC::throwTypeError(global_object, scope, WTF::makeString("Member "_s, name, " is required"_s));
            return std::nullopt;
        }
        double number = value.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto result = integerInRange<uint32_t>(number, 0, std::numeric_limits<uint32_t>::max());
        if (!result)
            JSC::throwTypeError(global_object, scope, "Value is outside the range [0, 4294967295]"_s);
        return result;
    }

    // A required member converted with ToNumber alone; the operation that uses it validates the value.
    std::optional<double> requiredNumber(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        JSValue value = member(global_object, object, name);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (value.isUndefined()) {
            JSC::throwTypeError(global_object, scope, WTF::makeString("Member "_s, name, " is required"_s));
            return std::nullopt;
        }
        double number = value.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return number;
    }

    const HashSpec* requiredHash(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        JSValue value = member(global_object, object, "hash"_s);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (value.isUndefined()) {
            JSC::throwTypeError(global_object, scope, "HashAlgorithmIdentifier is required"_s);
            return nullptr;
        }
        return normalizeHashAlgorithm(global_object, scope, value);
    }

    bool isAesGcmTagBits(uint32_t bits)
    {
        switch (bits) {
        case 32:
        case 64:
        case 96:
        case 104:
        case 112:
        case 120:
        case 128:
            return true;
        default:
            return false;
        }
    }

    std::optional<AlgorithmParams> readAesCbc(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto iv = requiredBufferSource(global_object, scope, object, "iv"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (iv->size() != 16) {
            throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
            return std::nullopt;
        }
        return AlgorithmParams { AesCbcParams { WTF::move(*iv) } };
    }

    std::optional<AlgorithmParams> readAesCtr(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto counter = requiredBufferSource(global_object, scope, object, "counter"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (counter->size() != 16) {
            throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
            return std::nullopt;
        }
        auto length = requiredNumber(global_object, scope, object, "length"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto counter_bits = integerInRange<uint8_t>(*length, 1, 128);
        if (!counter_bits) {
            throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
            return std::nullopt;
        }
        return AlgorithmParams { AesCtrParams { WTF::move(*counter), *counter_bits } };
    }

    std::optional<AlgorithmParams> readAesGcm(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto additional_data = optionalBufferSource(global_object, scope, object, "additionalData"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto iv = requiredBufferSource(global_object, scope, object, "iv"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (iv->isEmpty() || iv->size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
            throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
            return std::nullopt;
        }
        JSValue tag_length = member(global_object, object, "tagLength"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        size_t tag_bytes = 16;
        if (!tag_length.isUndefined()) {
            double number = tag_length.toNumber(global_object);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            auto bits = integerInRange<uint32_t>(number, 32, 128);
            if (!bits || !isAesGcmTagBits(*bits)) {
                throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
                return std::nullopt;
            }
            tag_bytes = *bits / 8;
        }
        return AlgorithmParams { AesGcmParams { WTF::move(*additional_data), WTF::move(*iv), tag_bytes } };
    }

    std::optional<AlgorithmParams> readAesLength(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto length = requiredNumber(global_object, scope, object, "length"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return AlgorithmParams { AesLengthParams { *length } };
    }

    std::optional<AlgorithmParams> readHmac(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto* hash = requiredHash(global_object, scope, object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        JSValue length = member(global_object, object, "length"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        std::optional<uint32_t> length_bits;
        if (!length.isUndefined()) {
            double number = length.toNumber(global_object);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            length_bits = integerInRange<uint32_t>(number, 1, std::numeric_limits<uint32_t>::max());
            if (!length_bits) {
                throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
                return std::nullopt;
            }
        }
        return AlgorithmParams { HmacParams { hash, length_bits } };
    }

    std::optional<AlgorithmParams> readHash(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto* hash = requiredHash(global_object, scope, object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return AlgorithmParams { HashParams { hash } };
    }

    // RsaHashedKeyGenParams inherits RsaKeyGenParams, and WebIDL converts an inherited dictionary's members first, so
    // `hash` is read after `modulusLength` and `publicExponent`.
    std::optional<AlgorithmParams> readRsaKeyGen(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, bool hashed)
    {
        auto modulus_bits = requiredUnsignedLong(global_object, scope, object, "modulusLength"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto public_exponent = requiredBufferSource(global_object, scope, object, "publicExponent"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        const HashSpec* hash = nullptr;
        if (hashed) {
            hash = requiredHash(global_object, scope, object);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
        }
        if (public_exponent->isEmpty()) {
            throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
            return std::nullopt;
        }
        return AlgorithmParams { RsaKeyGenParams { hash, *modulus_bits, WTF::move(*public_exponent) } };
    }

    std::optional<AlgorithmParams> readRsaPss(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto salt_length = requiredUnsignedLong(global_object, scope, object, "saltLength"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return AlgorithmParams { RsaPssParams { *salt_length } };
    }

    std::optional<AlgorithmParams> readRsaOaep(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto label = optionalBufferSource(global_object, scope, object, "label"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return AlgorithmParams { RsaOaepParams { WTF::move(*label) } };
    }

    std::optional<AlgorithmParams> readEcKey(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        JSValue value = member(global_object, object, "namedCurve"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (value.isUndefined()) {
            JSC::throwTypeError(global_object, scope, "Member namedCurve is required"_s);
            return std::nullopt;
        }
        String name = value.toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto curve = ecCurveFromName(name);
        if (!curve) {
            throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError);
            return std::nullopt;
        }
        return AlgorithmParams { EcKeyParams { *curve } };
    }

    std::optional<AlgorithmParams> readEcdhKeyDerive(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        JSValue value = member(global_object, object, "public"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto* public_key = dynamicDowncast<JSColloCryptoKey>(value);
        if (!public_key) {
            JSC::throwTypeError(global_object, scope, "EcdhKeyDeriveParams.public must be a CryptoKey"_s);
            return std::nullopt;
        }
        return AlgorithmParams { EcdhKeyDeriveParams { public_key } };
    }

    std::optional<AlgorithmParams> readPbkdf2(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto* hash = requiredHash(global_object, scope, object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto iterations = requiredUnsignedLong(global_object, scope, object, "iterations"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto salt = requiredBufferSource(global_object, scope, object, "salt"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return AlgorithmParams { Pbkdf2Params { hash, *iterations, WTF::move(*salt) } };
    }

    std::optional<AlgorithmParams> readHkdf(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object)
    {
        auto* hash = requiredHash(global_object, scope, object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto info = requiredBufferSource(global_object, scope, object, "info"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto salt = requiredBufferSource(global_object, scope, object, "salt"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return AlgorithmParams { HkdfParams { hash, WTF::move(*info), WTF::move(*salt) } };
    }

    // Reads the dictionary `registration` names from `object`, which is null for an algorithm given as a string.
    std::optional<AlgorithmParams> readParams(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const Registration& registration, JSC::JSObject* object)
    {
        // Every dictionary but these two has a required member, which a string cannot carry.
        const bool members_optional
            = registration.params == ParamsKind::None || registration.params == ParamsKind::RsaOaep;
        if (!object && !members_optional) {
            JSC::throwTypeError(global_object, scope,
                WTF::makeString(algorithmSpec(registration.algorithm).name, " algorithm requires parameters"_s));
            return std::nullopt;
        }
        switch (registration.params) {
        case ParamsKind::None:
            return AlgorithmParams { std::monostate {} };
        case ParamsKind::AesCbc:
            return readAesCbc(global_object, scope, object);
        case ParamsKind::AesCtr:
            return readAesCtr(global_object, scope, object);
        case ParamsKind::AesGcm:
            return readAesGcm(global_object, scope, object);
        case ParamsKind::AesLength:
            return readAesLength(global_object, scope, object);
        case ParamsKind::Hmac:
            return readHmac(global_object, scope, object);
        case ParamsKind::Hash:
            return readHash(global_object, scope, object);
        case ParamsKind::RsaKeyGen:
            return readRsaKeyGen(global_object, scope, object, false);
        case ParamsKind::RsaHashedKeyGen:
            return readRsaKeyGen(global_object, scope, object, true);
        case ParamsKind::RsaPss:
            return readRsaPss(global_object, scope, object);
        case ParamsKind::RsaOaep:
            return readRsaOaep(global_object, scope, object);
        case ParamsKind::EcKey:
            return readEcKey(global_object, scope, object);
        case ParamsKind::EcdhKeyDerive:
            return readEcdhKeyDerive(global_object, scope, object);
        case ParamsKind::Pbkdf2:
            return readPbkdf2(global_object, scope, object);
        case ParamsKind::Hkdf:
            return readHkdf(global_object, scope, object);
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    uint8_t usageBit(const String& name)
    {
        for (const auto& usage : orderedCryptoKeyUsages) {
            if (name == usage.name)
                return usage.bit;
        }
        return 0;
    }

    // Calls `visit` with each entry of an array-like list of strings, as a sequence<DOMString> of at most
    // `key_usages_length_max` entries, and stops at the first entry `visit` refuses by returning false, as a sequence
    // conversion stops at the first entry it cannot convert.
    template <typename Visit>
    void readStringList(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, const Visit& visit)
    {
        auto* object = dynamicDowncast<JSC::JSObject>(value);
        if (!object) {
            JSC::throwTypeError(global_object, scope, "Key usages must be an array-like object"_s);
            return;
        }
        uint64_t length = JSC::toLength(global_object, object);
        RETURN_IF_EXCEPTION(scope, void());
        if (length > key_usages_length_max) {
            JSC::throwTypeError(global_object, scope, "Key usages is too large"_s);
            return;
        }
        for (uint64_t index = 0; index < length; ++index) {
            JSValue item = object->get(global_object, static_cast<unsigned>(index));
            RETURN_IF_EXCEPTION(scope, void());
            String name = item.toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, void());
            if (!visit(name))
                return;
        }
    }

} // namespace

std::optional<NormalizedAlgorithm> normalizeAlgorithm(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, Operation operation, JSValue value)
{
    JSC::JSObject* object = nullptr;
    String name = algorithmName(global_object, scope, value, object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    auto* registration = findRegistration(operation, name);
    if (!registration) {
        throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return std::nullopt;
    }
    auto params = readParams(global_object, scope, *registration, object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return NormalizedAlgorithm { registration->algorithm, WTF::move(*params) };
}

const HashSpec* normalizeHashAlgorithm(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    JSC::JSObject* object = nullptr;
    String name = algorithmName(global_object, scope, value, object);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* hash = hashSpecFromName(name);
    if (!hash)
        throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
    return hash;
}

std::optional<KeyFormat> parseKeyFormat(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    String format = value.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (format == "raw"_s)
        return KeyFormat::Raw;
    if (format == "spki"_s)
        return KeyFormat::Spki;
    if (format == "pkcs8"_s)
        return KeyFormat::Pkcs8;
    if (format == "jwk"_s)
        return KeyFormat::Jwk;
    JSC::throwTypeError(global_object, scope, "Invalid KeyFormat"_s);
    return std::nullopt;
}

std::optional<uint8_t> parseKeyUsages(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    uint8_t usages = 0;
    readStringList(global_object, scope, value, [&](const String& name) {
        uint8_t bit = usageBit(name);
        if (!bit) {
            JSC::throwTypeError(global_object, scope, "value must be enumeration (string)"_s);
            return false;
        }
        usages |= bit;
        return true;
    });
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return usages;
}

std::optional<KeyOps> readKeyOps(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    KeyOps key_ops;
    readStringList(global_object, scope, value, [&](const String& name) {
        noteKeyOp(key_ops, name);
        return true;
    });
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return key_ops;
}

void noteKeyOp(KeyOps& key_ops, const String& name)
{
    const uint8_t bit = usageBit(name);
    key_ops.usages |= bit;
    if (!bit)
        key_ops.names_unknown_usage = true;
}

JSC::JSArray* createUsagesArray(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, uint8_t usages)
{
    auto& vm = global_object->vm();
    auto* result = JSC::constructEmptyArray(global_object, nullptr, 0);
    RETURN_IF_EXCEPTION(scope, nullptr);
    unsigned index = 0;
    for (const auto& usage : orderedCryptoKeyUsages) {
        if (!(usages & usage.bit))
            continue;
        result->putDirectIndex(global_object, index++, JSC::jsString(vm, String(usage.name)));
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return result;
}

std::optional<SecretBytes> copySecretBufferSource(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    auto bytes = Collo::JscSupport::borrowBufferSource(global_object, scope, value);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    SecretBytes copy;
    if (!copy.tryAppend(*bytes)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return std::nullopt;
    }
    return copy;
}

}
