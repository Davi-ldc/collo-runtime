// Argument normalization declared in `normalize.h`, on the VM thread. Any property read or conversion of a script
// value can run a getter or `valueOf` that throws, so each one is followed by `takePendingException`, or goes through
// a helper such as `copyBufferSource` that does the same, moving the exception into `out_error`. A new read keeps
// that pattern.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/normalize.h"

#include "host_functions/webapi/crypto/keys.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <cmath>
#include <limits>

namespace Collo::HostFunctions::WebCrypto {

using JSC::JSValue;
using WTF::String;
using namespace Collo::JscSupport;

bool algorithmName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value, String& out,
    JSC::JSValue& out_error)
{
    if (value.isString()) {
        out = value.toWTFString(global_object);
        return !takePendingException(scope, out_error);
    }

    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "Algorithm must be a string or object"_s);
        return false;
    }

    auto name_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "name"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (name_value.isUndefined()) {
        out_error = typeErrorValue(global_object, "Algorithm name is required"_s);
        return false;
    }
    out = valueToStringForPromise(global_object, scope, name_value, out_error);
    return !out_error;
}

bool normalizeHashAlgorithm(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const HashSpec*& out, JSC::JSValue& out_error)
{
    String name;
    if (!algorithmName(global_object, scope, value, name, out_error))
        return false;
    out = hashSpecFromName(name);
    if (!out) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    return true;
}

bool normalizeHmacAlgorithmAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, const HashSpec*& out_hash, std::optional<size_t>& out_length_bits, JSC::JSValue& out_error)
{
    auto* object = dynamicDowncast<JSC::JSObject>(value);

    if (!WTF::equalIgnoringASCIICase(name, "HMAC"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    if (!object) {
        out_error = typeErrorValue(global_object, "HMAC algorithm requires parameters"_s);
        return false;
    }

    auto hash_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "hash"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (hash_value.isUndefined()) {
        out_error = typeErrorValue(global_object, "HMAC hash is required"_s);
        return false;
    }
    if (!normalizeHashAlgorithm(global_object, scope, hash_value, out_hash, out_error))
        return false;

    auto length_value
        = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "length"_s));
    if (takePendingException(scope, out_error))
        return false;
    out_length_bits = std::nullopt;
    if (length_value && !length_value.isUndefined()) {
        double number = length_value.toNumber(global_object);
        if (takePendingException(scope, out_error))
            return false;
        uint32_t length_bits = 0;
        if (!checkedUInt32FromNumber(number, 1, std::numeric_limits<uint32_t>::max(), length_bits)) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
            return false;
        }
        out_length_bits = length_bits;
    }
    return true;
}

bool normalizeHmacAlgorithm(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const HashSpec*& out_hash, std::optional<size_t>& out_length_bits, JSC::JSValue& out_error)
{
    String name;
    if (!algorithmName(global_object, scope, value, name, out_error))
        return false;
    return normalizeHmacAlgorithmAfterName(global_object, scope, value, name, out_hash, out_length_bits, out_error);
}

bool normalizeHmacOperation(
    JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value, JSC::JSValue& out_error)
{
    String name;
    if (!algorithmName(global_object, scope, value, name, out_error))
        return false;
    if (!WTF::equalIgnoringASCIICase(name, "HMAC"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    return true;
}

bool normalizeAesNameAfterName(JSValue value, const String& name, CryptoKeyAlgorithm expected,
    JSC::JSObject*& out_object, JSC::JSValue& out_error, JSC::JSGlobalObject* global_object)
{
    out_object = dynamicDowncast<JSC::JSObject>(value);
    auto algorithm = aesAlgorithmFromName(name);
    if (!algorithm || *algorithm != expected) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    return true;
}

static bool parseKeyUsagesCommon(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    bool unknown_usage_is_data_error, uint8_t& out, JSC::JSValue& out_error)
{
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "Key usages must be an array-like object"_s);
        return false;
    }

    auto length = JSC::toLength(global_object, object);
    if (takePendingException(scope, out_error))
        return false;
    if (length > 64) {
        out_error = typeErrorValue(global_object, "Key usages is too large"_s);
        return false;
    }

    uint8_t usages = 0;
    for (uint64_t index = 0; index < length; ++index) {
        auto item = object->get(global_object, static_cast<unsigned>(index));
        if (takePendingException(scope, out_error))
            return false;
        auto usage = valueToStringForPromise(global_object, scope, item, out_error);
        if (out_error)
            return false;
        uint8_t bit = 0;
        for (const auto& known : orderedCryptoKeyUsages) {
            if (usage == known.name) {
                bit = known.bit;
                break;
            }
        }
        if (!bit) {
            out_error = unknown_usage_is_data_error
                ? domExceptionValue(global_object, DOMExceptionCode::DataError)
                : typeErrorValue(global_object, "value must be enumeration (string)"_s);
            return false;
        }
        usages |= bit;
    }

    out = usages;
    return true;
}

bool parseKeyUsages(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value, uint8_t& out,
    JSC::JSValue& out_error)
{
    return parseKeyUsagesCommon(global_object, scope, value, false, out, out_error);
}

bool parseJwkKeyOps(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value, uint8_t& out,
    JSC::JSValue& out_error)
{
    return parseKeyUsagesCommon(global_object, scope, value, true, out, out_error);
}

bool validateRequestedUsages(
    uint8_t usages, uint8_t allowed, JSC::JSValue& out_error, JSC::JSGlobalObject* global_object)
{
    if (usages & ~allowed) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::SyntaxError, "A required parameter was missing or out-of-range"_s);
        return false;
    }
    return true;
}

bool validateRequiredUsages(uint8_t usages, JSC::JSValue& out_error, JSC::JSGlobalObject* global_object)
{
    if (!usages) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::SyntaxError, "A required parameter was missing or out-of-range"_s);
        return false;
    }
    return true;
}

JSC::JSArray* createUsagesArray(JSC::JSGlobalObject* global_object, JSC::VM& vm, uint8_t usages)
{
    auto* result = JSC::constructEmptyArray(global_object, nullptr, 0);
    if (!result)
        return nullptr;
    unsigned index = 0;
    for (const auto& usage : orderedCryptoKeyUsages) {
        if (!(usages & usage.bit))
            continue;
        if (!result->putDirectIndex(global_object, index++, JSC::jsString(vm, String(usage.name))))
            return nullptr;
    }
    return result;
}

static bool getRequiredBufferSourcePropertyCopy(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    JSC::JSObject* object, WTF::ASCIILiteral name, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    auto value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), name));
    if (takePendingException(scope, out_error))
        return false;
    if (value.isUndefined()) {
        out_error = typeErrorValue(global_object,
            WTF::makeString(
                "Member "_s, name, " is required and must be an instance of (ArrayBufferView or ArrayBuffer)"_s));
        return false;
    }
    out.clear();
    return copyBufferSource(global_object, scope, value, out, out_error);
}

static bool getRequiredHashProperty(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    JSC::JSObject* object, const HashSpec*& out, JSC::JSValue& out_error)
{
    auto value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "hash"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (value.isUndefined()) {
        out_error = typeErrorValue(global_object, "HashAlgorithmIdentifier is required"_s);
        return false;
    }
    return normalizeHashAlgorithm(global_object, scope, value, out, out_error);
}

static bool getRequiredOpenSslEvpHashProperty(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    JSC::JSObject* object, const HashSpec*& out, JSC::JSValue& out_error)
{
    if (!getRequiredHashProperty(global_object, scope, object, out, out_error))
        return false;
    if (hashHasOpenSslEvp(*out))
        return true;

    out_error = domExceptionValue(
        global_object, DOMExceptionCode::NotSupportedError, "Hash algorithm is not supported for this operation"_s);
    return false;
}

static bool getRequiredUnsignedLongProperty(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    JSC::JSObject* object, WTF::ASCIILiteral name, uint32_t& out, JSC::JSValue& out_error)
{
    auto value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), name));
    if (takePendingException(scope, out_error))
        return false;
    if (value.isUndefined()) {
        out_error = typeErrorValue(global_object, WTF::makeString("Member "_s, name, " is required"_s));
        return false;
    }
    double number = value.toNumber(global_object);
    if (takePendingException(scope, out_error))
        return false;
    if (!checkedUInt32FromNumber(number, 0, std::numeric_limits<uint32_t>::max(), out)) {
        out_error = typeErrorValue(global_object, "Value is outside the range [0, 4294967295]"_s);
        return false;
    }
    return true;
}

bool parseAesGcmParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, AesGcmParams& out, JSC::JSValue& out_error)
{
    JSC::JSObject* object = nullptr;
    if (!normalizeAesNameAfterName(value, name, CryptoKeyAlgorithm::AesGcm, object, out_error, global_object))
        return false;
    if (!object) {
        out_error = typeErrorValue(global_object, "AES-GCM algorithm requires parameters"_s);
        return false;
    }

    auto iv_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "iv"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (iv_value.isUndefined()) {
        out_error = typeErrorValue(global_object, "AES-GCM iv is required"_s);
        return false;
    }
    out.iv.clear();
    if (!copyBufferSource(global_object, scope, iv_value, out.iv, out_error))
        return false;
    if (out.iv.isEmpty() || out.iv.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }

    auto additional_data_value = object->getIfPropertyExists(
        global_object, JSC::Identifier::fromString(global_object->vm(), "additionalData"_s));
    if (takePendingException(scope, out_error))
        return false;
    out.additional_data.clear();
    if (additional_data_value && !additional_data_value.isUndefined()) {
        if (!copyBufferSource(global_object, scope, additional_data_value, out.additional_data, out_error))
            return false;
    }

    auto tag_length_value
        = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "tagLength"_s));
    if (takePendingException(scope, out_error))
        return false;
    out.tag_bytes = 16;
    if (tag_length_value && !tag_length_value.isUndefined()) {
        double number = tag_length_value.toNumber(global_object);
        if (takePendingException(scope, out_error))
            return false;
        uint8_t bits = 0;
        if (!checkedUInt8FromNumber(number, 32, 128, bits)) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
            return false;
        }
        switch (bits) {
        case 32:
        case 64:
        case 96:
        case 104:
        case 112:
        case 120:
        case 128:
            out.tag_bytes = static_cast<size_t>(bits / 8);
            return true;
        default:
            out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
            return false;
        }
    }
    return true;
}

bool parseAesCbcParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, AesCbcParams& out, JSC::JSValue& out_error)
{
    JSC::JSObject* object = nullptr;
    if (!normalizeAesNameAfterName(value, name, CryptoKeyAlgorithm::AesCbc, object, out_error, global_object))
        return false;
    if (!object) {
        out_error = typeErrorValue(global_object, "AES-CBC algorithm requires parameters"_s);
        return false;
    }

    if (!getRequiredBufferSourcePropertyCopy(global_object, scope, object, "iv"_s, out.iv, out_error))
        return false;
    if (out.iv.size() != 16) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool parseAesCfbParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, AesCfbParams& out, JSC::JSValue& out_error)
{
    JSC::JSObject* object = nullptr;
    if (!normalizeAesNameAfterName(value, name, CryptoKeyAlgorithm::AesCfb, object, out_error, global_object))
        return false;
    if (!object) {
        out_error = typeErrorValue(global_object, "AES-CFB-8 algorithm requires parameters"_s);
        return false;
    }

    if (!getRequiredBufferSourcePropertyCopy(global_object, scope, object, "iv"_s, out.iv, out_error))
        return false;
    if (out.iv.size() != 16) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool parseAesCtrParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, AesCtrParams& out, JSC::JSValue& out_error)
{
    JSC::JSObject* object = nullptr;
    if (!normalizeAesNameAfterName(value, name, CryptoKeyAlgorithm::AesCtr, object, out_error, global_object))
        return false;
    if (!object) {
        out_error = typeErrorValue(global_object, "AES-CTR algorithm requires parameters"_s);
        return false;
    }

    if (!getRequiredBufferSourcePropertyCopy(global_object, scope, object, "counter"_s, out.counter, out_error))
        return false;
    if (out.counter.size() != 16) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }

    auto length_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "length"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (length_value.isUndefined()) {
        out_error = typeErrorValue(global_object, "AES-CTR length is required"_s);
        return false;
    }
    double number = length_value.toNumber(global_object);
    if (takePendingException(scope, out_error))
        return false;
    if (!checkedUInt8FromNumber(number, 1, 128, out.length)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool parseAesKwParamsAfterName(
    JSC::JSGlobalObject* global_object, const String& name, JSValue value, JSC::JSValue& out_error)
{
    JSC::JSObject* object = nullptr;
    return normalizeAesNameAfterName(value, name, CryptoKeyAlgorithm::AesKw, object, out_error, global_object);
}

bool parsePbkdf2ParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, Pbkdf2Params& out, JSC::JSValue& out_error)
{
    if (!WTF::equalIgnoringASCIICase(name, "PBKDF2"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "PBKDF2 algorithm requires parameters"_s);
        return false;
    }
    if (!getRequiredBufferSourcePropertyCopy(global_object, scope, object, "salt"_s, out.salt, out_error)
        || !getRequiredUnsignedLongProperty(global_object, scope, object, "iterations"_s, out.iterations, out_error)
        || !getRequiredOpenSslEvpHashProperty(global_object, scope, object, out.hash, out_error))
        return false;
    if (!out.iterations || out.iterations > maxWebCryptoPbkdf2Iterations) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::OperationError, "PBKDF2 iterations exceed Collo WebCrypto limits"_s);
        return false;
    }
    return true;
}

bool parseHkdfParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, HkdfParams& out, JSC::JSValue& out_error)
{
    if (!WTF::equalIgnoringASCIICase(name, "HKDF"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "HKDF algorithm requires parameters"_s);
        return false;
    }
    return getRequiredOpenSslEvpHashProperty(global_object, scope, object, out.hash, out_error)
        && getRequiredBufferSourcePropertyCopy(global_object, scope, object, "salt"_s, out.salt, out_error)
        && getRequiredBufferSourcePropertyCopy(global_object, scope, object, "info"_s, out.info, out_error);
}

bool normalizeRsaHashedAlgorithmAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    JSValue value, const String& name, CryptoKeyAlgorithm expected, const HashSpec*& out_hash, JSC::JSValue& out_error)
{
    auto algorithm = rsaAlgorithmFromName(name);
    if (!algorithm || *algorithm != expected) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "RSA algorithm requires parameters"_s);
        return false;
    }
    return getRequiredOpenSslEvpHashProperty(global_object, scope, object, out_hash, out_error);
}

bool parseRsaHashedKeyGenParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    JSValue value, const String& name, CryptoKeyAlgorithm expected, RsaHashedKeyGenParams& out, JSC::JSValue& out_error)
{
    if (!normalizeRsaHashedAlgorithmAfterName(global_object, scope, value, name, expected, out.hash, out_error))
        return false;
    auto* object = JSC::asObject(value);
    if (!getRequiredUnsignedLongProperty(
            global_object, scope, object, "modulusLength"_s, out.modulus_length, out_error))
        return false;
    if (!getRequiredBufferSourcePropertyCopy(
            global_object, scope, object, "publicExponent"_s, out.public_exponent, out_error))
        return false;
    if (out.public_exponent.isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool parseRsaKeyGenParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, CryptoKeyAlgorithm expected, RsaKeyGenParams& out, JSC::JSValue& out_error)
{
    auto algorithm = rsaAlgorithmFromName(name);
    if (!algorithm || *algorithm != expected) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "RSA algorithm requires parameters"_s);
        return false;
    }
    if (!getRequiredUnsignedLongProperty(
            global_object, scope, object, "modulusLength"_s, out.modulus_length, out_error))
        return false;
    if (!getRequiredBufferSourcePropertyCopy(
            global_object, scope, object, "publicExponent"_s, out.public_exponent, out_error))
        return false;
    if (out.public_exponent.isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool parseRsaPssParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, RsaPssParams& out, JSC::JSValue& out_error)
{
    if (!WTF::equalIgnoringASCIICase(name, "RSA-PSS"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "RSA-PSS algorithm requires parameters"_s);
        return false;
    }
    return getRequiredUnsignedLongProperty(global_object, scope, object, "saltLength"_s, out.salt_length, out_error);
}

bool parseRsaOaepParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, RsaOaepParams& out, JSC::JSValue& out_error)
{
    if (!WTF::equalIgnoringASCIICase(name, "RSA-OAEP"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    out.label.clear();
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object)
        return true;
    auto label_value
        = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "label"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (label_value && !label_value.isUndefined())
        return copyBufferSource(global_object, scope, label_value, out.label, out_error);
    return true;
}

bool parseEcKeyParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, CryptoKeyAlgorithm expected, EcKeyParams& out, JSC::JSValue& out_error)
{
    auto algorithm = ecAlgorithmFromName(name);
    if (!algorithm || *algorithm != expected) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "EC algorithm requires parameters"_s);
        return false;
    }

    auto curve_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "namedCurve"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (curve_value.isUndefined()) {
        out_error = typeErrorValue(global_object, "EcKeyGenParams.namedCurve is required"_s);
        return false;
    }
    auto curve_name = valueToStringForPromise(global_object, scope, curve_value, out_error);
    if (out_error)
        return false;
    auto curve = namedCurveFromName(curve_name);
    if (!curve) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
        return false;
    }
    out.named_curve = *curve;
    return true;
}

bool parseEcdsaParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, EcdsaParams& out, JSC::JSValue& out_error)
{
    if (!WTF::equalIgnoringASCIICase(name, "ECDSA"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "ECDSA algorithm requires parameters"_s);
        return false;
    }
    return getRequiredOpenSslEvpHashProperty(global_object, scope, object, out.hash, out_error);
}

bool parseEcdhParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, EcdhParams& out, JSC::JSValue& out_error)
{
    if (!WTF::equalIgnoringASCIICase(name, "ECDH"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "ECDH algorithm requires parameters"_s);
        return false;
    }
    auto public_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "public"_s));
    if (takePendingException(scope, out_error))
        return false;
    auto* public_key = dynamicDowncast<JSColloCryptoKey>(public_value);
    if (!public_key) {
        out_error = typeErrorValue(global_object, "EcdhKeyDeriveParams.public must be a CryptoKey"_s);
        return false;
    }
    out.public_key = public_key;
    return true;
}

bool parseX25519ParamsAfterName(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, X25519Params& out, JSC::JSValue& out_error)
{
    if (!WTF::equalIgnoringASCIICase(name, "X25519"_s)) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        out_error = typeErrorValue(global_object, "X25519 algorithm requires parameters"_s);
        return false;
    }
    auto public_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "public"_s));
    if (takePendingException(scope, out_error))
        return false;
    auto* public_key = dynamicDowncast<JSColloCryptoKey>(public_value);
    if (!public_key) {
        out_error = typeErrorValue(global_object, "X25519Params.public must be a CryptoKey"_s);
        return false;
    }
    out.public_key = public_key;
    return true;
}

bool parseDeriveBitsLength(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    size_t& out_bits, JSC::JSValue& out_error)
{
    if (value.isUndefined() || value.isNull()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    double number = value.toNumber(global_object);
    if (takePendingException(scope, out_error))
        return false;
    uint32_t bits = 0;
    if (!checkedUInt32FromNumber(number, 1, std::numeric_limits<uint32_t>::max(), bits) || bits % 8) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    if ((static_cast<size_t>(bits) / 8) > maxWebCryptoDerivedBytes) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    out_bits = bits;
    return true;
}

bool parseKdfDeriveBitsLength(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    size_t default_length_bits, size_t& out_bits, JSC::JSValue& out_error)
{
    if (value.isUndefined() || value.isNull()) {
        out_bits = default_length_bits;
        return true;
    }
    double number = value.toNumber(global_object);
    if (takePendingException(scope, out_error))
        return false;
    uint32_t bits = 0;
    if (!checkedUInt32FromNumber(number, 0, std::numeric_limits<uint32_t>::max(), bits) || bits % 8) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    if ((static_cast<size_t>(bits) / 8) > maxWebCryptoDerivedBytes) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    out_bits = bits;
    return true;
}

bool parseEcDeriveBitsLength(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    size_t full_length_bits, size_t& out_bits, JSC::JSValue& out_error)
{
    if (value.isUndefined() || value.isNull()) {
        out_bits = full_length_bits;
        return true;
    }
    double number = value.toNumber(global_object);
    if (takePendingException(scope, out_error))
        return false;
    size_t bits = 0;
    if (!checkedSizeFromNumber(number, 0, full_length_bits, bits)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    out_bits = bits ? bits : full_length_bits;
    return true;
}

static bool parseAesDerivedKeySpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, CryptoKeyAlgorithm algorithm, DerivedKeySpec& out, JSC::JSValue& out_error)
{
    JSC::JSObject* object = nullptr;
    if (!normalizeAesNameAfterName(value, name, algorithm, object, out_error, global_object))
        return false;
    if (!object) {
        out_error = typeErrorValue(global_object, "AES key derivation requires parameters"_s);
        return false;
    }

    auto length_value = object->get(global_object, JSC::Identifier::fromString(global_object->vm(), "length"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (length_value.isUndefined()) {
        out_error = typeErrorValue(
            global_object, "Member AesKeyParams.length is required and must be an instance of unsigned short"_s);
        return false;
    }

    double number = length_value.toNumber(global_object);
    if (takePendingException(scope, out_error))
        return false;
    size_t bits = 0;
    if (!checkedSizeFromNumber(number, 128, 256, bits)) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::OperationError, "Cannot get key length from derivedKeyType"_s);
        return false;
    }

    if (bits != 128 && bits != 192 && bits != 256) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::OperationError, "Cannot get key length from derivedKeyType"_s);
        return false;
    }

    out.algorithm = algorithm;
    out.hash = nullptr;
    out.length_bits = bits;
    return true;
}

static bool parseHmacDerivedKeySpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    const String& name, DerivedKeySpec& out, JSC::JSValue& out_error)
{
    const HashSpec* hash = nullptr;
    std::optional<size_t> length_bits;
    if (!normalizeHmacAlgorithmAfterName(global_object, scope, value, name, hash, length_bits, out_error))
        return false;

    auto bits = length_bits.value_or(hash->default_hmac_bits);
    if (!bits || bits / 8 > maxWebCryptoGeneratedSecretBytes) {
        out_error = typeErrorValue(global_object, "Cannot get key length from derivedKeyType"_s);
        return false;
    }
    if ((bits % 8) != 0) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::OperationError, "Cannot get key length from derivedKeyType"_s);
        return false;
    }

    out.algorithm = CryptoKeyAlgorithm::Hmac;
    out.hash = hash;
    out.length_bits = bits;
    return true;
}

bool parseDerivedKeySpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue value,
    DerivedKeySpec& out, JSC::JSValue& out_error)
{
    String name;
    if (!algorithmName(global_object, scope, value, name, out_error))
        return false;

    if (auto aes_algorithm = aesAlgorithmFromName(name))
        return parseAesDerivedKeySpec(global_object, scope, value, name, *aes_algorithm, out, out_error);
    if (WTF::equalIgnoringASCIICase(name, "HMAC"_s))
        return parseHmacDerivedKeySpec(global_object, scope, value, name, out, out_error);

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

} // namespace Collo::HostFunctions::WebCrypto
