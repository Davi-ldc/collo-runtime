// Import of "raw" key data: HMAC, AES, PBKDF2 and HKDF secrets, and EC, Ed25519 and X25519 public keys, under the
// contract in key_io.h. Imported secret bytes stay under a SecureVectorGuard until the new CryptoKey owns them.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/key_io/key_io.h"

#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/nid.h>
#include <openssl/pkcs8.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>

namespace Collo::HostFunctions::WebCrypto {

using JSC::JSValue;
using WTF::String;
using namespace Collo::JscSupport;

static bool isUncompressedEcPoint(std::span<const uint8_t> bytes, size_t coordinate_bytes)
{
    if (!coordinate_bytes)
        return false;
    return bytes.size() == 1 + 2 * coordinate_bytes && bytes[0] == 0x04;
}

bool makeHmacKeyFromRaw(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    const HashSpec* hash = nullptr;
    std::optional<size_t> length_bits;
    if (!normalizeHmacAlgorithmAfterName(
            global_object, scope, algorithm_value, algorithm_name, hash, length_bits, out_error))
        return false;

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, CryptoKeyUsageSign | CryptoKeyUsageVerify, out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;

    WTF::Vector<uint8_t> material;
    if (!copyBufferSource(global_object, scope, key_data_value, material, out_error))
        return false;
    SecureVectorGuard material_guard(material);
    if (material.isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    // Web Crypto HMAC import requires a declared length to satisfy data_bits - 8 < length <= data_bits.
    if (length_bits && (*length_bits > material.size() * 8 || *length_bits + 8 <= material.size() * 8)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createHmacKey(global_object, hash->id, WTF::move(material), extractable_value.toBoolean(global_object),
        usages, length_bits.value_or(0));
    if (out_key)
        material_guard.dismiss();
    return !takePendingException(scope, out_error);
}

bool makeAesKeyFromRaw(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto algorithm = aesAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    JSC::JSObject* object = nullptr;
    if (!normalizeAesNameAfterName(algorithm_value, algorithm_name, *algorithm, object, out_error, global_object))
        return false;

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, allowedUsagesForAes(*algorithm), out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;

    WTF::Vector<uint8_t> material;
    if (!copyBufferSource(global_object, scope, key_data_value, material, out_error))
        return false;
    SecureVectorGuard material_guard(material);
    if (!isValidAesKeyLength(material.size())) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    // AES import takes a plain Algorithm dictionary, so a "length" member is ignored.
    out_key = createAesKey(
        global_object, *algorithm, WTF::move(material), extractable_value.toBoolean(global_object), usages);
    if (out_key)
        material_guard.dismiss();
    return !takePendingException(scope, out_error);
}

bool makeDeriveKeyFromRaw(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    CryptoKeyAlgorithm algorithm, JSValue extractable_value, JSValue usages_value, JSColloCryptoKey*& out_key,
    JSC::JSValue& out_error)
{
    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, CryptoKeyUsageDeriveBits | CryptoKeyUsageDeriveKey, out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;
    if (extractable_value.toBoolean(global_object)) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::SyntaxError, "A required parameter was missing or out-of-range"_s);
        return false;
    }

    WTF::Vector<uint8_t> material;
    if (!copyBufferSource(global_object, scope, key_data_value, material, out_error))
        return false;
    SecureVectorGuard material_guard(material);

    out_key = createRawDeriveKey(global_object, algorithm, WTF::move(material), usages);
    if (out_key)
        material_guard.dismiss();
    return !takePendingException(scope, out_error);
}

bool makeEcKeyFromRaw(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto algorithm = ecAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    EcKeyParams params;
    if (!parseEcKeyParamsAfterName(
            global_object, scope, algorithm_value, algorithm_name, *algorithm, params, out_error))
        return false;

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, allowedPublicUsagesForEc(*algorithm), out_error, global_object))
        return false;

    WTF::Vector<uint8_t> bytes;
    SecureVectorGuard bytes_guard(bytes);
    if (!copyBufferSource(global_object, scope, key_data_value, bytes, out_error))
        return false;
    // A raw EC key is accepted only as an uncompressed point, a 0x04 octet followed by both affine coordinates. Web
    // Crypto requires support for that form and lets an implementation reject compressed points (0x02 and 0x03) with
    // a DataError; EC_POINT_oct2point would otherwise decode them.
    if (!isUncompressedEcPoint(bytes.span(), coordinateBytesForNamedCurve(params.named_curve))) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    bssl::UniquePtr<EC_KEY> ec(EC_KEY_new_by_curve_name(nidForNamedCurve(params.named_curve)));
    if (!ec) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    auto* group = EC_KEY_get0_group(ec.get());
    bssl::UniquePtr<EC_POINT> point(group ? EC_POINT_new(group) : nullptr);
    if (!group || !point || EC_POINT_oct2point(group, point.get(), bytes.span().data(), bytes.size(), nullptr) != 1
        || EC_KEY_set_public_key(ec.get(), point.get()) != 1 || EC_KEY_check_key(ec.get()) != 1) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto pkey = pkeyFromEc(ec.get());
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    out_key = createEcKey(global_object, *algorithm, CryptoKeyType::Public, params.named_curve, WTF::move(pkey),
        extractable_value.toBoolean(global_object), usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

bool makeOkpKeyFromRaw(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    const String& algorithm_name, JSValue extractable_value, JSValue usages_value, JSColloCryptoKey*& out_key,
    JSC::JSValue& out_error)
{
    auto algorithm = okpAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, allowedPublicUsagesForOkp(*algorithm), out_error, global_object))
        return false;

    WTF::Vector<uint8_t> bytes;
    if (!copyBufferSource(global_object, scope, key_data_value, bytes, out_error))
        return false;
    if (bytes.size() != 32) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    bssl::UniquePtr<EVP_PKEY> pkey(
        EVP_PKEY_new_raw_public_key(evpTypeForOkp(*algorithm), nullptr, bytes.span().data(), bytes.size()));
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createOkpKey(global_object, *algorithm, CryptoKeyType::Public, WTF::move(pkey),
        extractable_value.toBoolean(global_object), usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

bool makeDerivedKeyFromMaterial(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    WTF::Vector<uint8_t>&& material, const DerivedKeySpec& spec, bool extractable, uint8_t usages,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    SecureVectorGuard material_guard(material);
    if (material.size() * 8 != spec.length_bits) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    if (isAesAlgorithm(spec.algorithm)) {
        if (!validateRequestedUsages(usages, allowedUsagesForAes(spec.algorithm), out_error, global_object))
            return false;
        if (!validateRequiredUsages(usages, out_error, global_object))
            return false;
        if (!isValidAesKeyLength(material.size())) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        out_key = createAesKey(global_object, spec.algorithm, WTF::move(material), extractable, usages);
        if (out_key)
            material_guard.dismiss();
        return !takePendingException(scope, out_error);
    }

    ASSERT(spec.algorithm == CryptoKeyAlgorithm::Hmac);
    if (!validateRequestedUsages(usages, CryptoKeyUsageSign | CryptoKeyUsageVerify, out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;
    if (material.isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    out_key = createHmacKey(global_object, spec.hash->id, WTF::move(material), extractable, usages);
    if (out_key)
        material_guard.dismiss();
    return !takePendingException(scope, out_error);
}

} // namespace Collo::HostFunctions::WebCrypto
