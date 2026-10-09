// Import of "spki" and "pkcs8" DER for RSA, EC and OKP keys, and the "raw", "spki" and "pkcs8" exports of asymmetric
// keys, under the contract in key_io.h. An import accepts the DER only when it parses to the end of the buffer and
// holds the key type the algorithm names; any other input is a DataError.

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

bool evpGetRawPublic(EVP_PKEY* pkey, WTF::Vector<uint8_t>& out)
{
    size_t length = 0;
    if (EVP_PKEY_get_raw_public_key(pkey, nullptr, &length) != 1 || !length || !out.tryReserveInitialCapacity(length))
        return false;
    out.grow(length);
    return EVP_PKEY_get_raw_public_key(pkey, out.mutableSpan().data(), &length) == 1 && length == out.size();
}

bool makeRsaKeyFromSpki(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto algorithm = rsaAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    WebCryptoHash hash { WebCryptoHash::SHA1 };
    if (*algorithm != CryptoKeyAlgorithm::RsaEsPkcs1V15) {
        const HashSpec* hash_spec = nullptr;
        if (!normalizeRsaHashedAlgorithmAfterName(
                global_object, scope, algorithm_value, algorithm_name, *algorithm, hash_spec, out_error))
            return false;
        hash = hash_spec->id;
    }

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, allowedPublicUsagesForRsa(*algorithm), out_error, global_object))
        return false;

    WTF::Vector<uint8_t> bytes;
    if (!copyBufferSource(global_object, scope, key_data_value, bytes, out_error))
        return false;
    SecureVectorGuard bytes_guard(bytes);
    const uint8_t* ptr = bytes.span().data();
    const uint8_t* end = ptr + bytes.size();
    bssl::UniquePtr<EVP_PKEY> pkey(d2i_PUBKEY(nullptr, &ptr, bytes.size()));
    if (!pkey || ptr != end || EVP_PKEY_id(pkey.get()) != EVP_PKEY_RSA) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createRsaKey(global_object, *algorithm, hash, CryptoKeyType::Public, WTF::move(pkey),
        extractable_value.toBoolean(global_object), usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

bool makeRsaKeyFromPkcs8(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto algorithm = rsaAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    WebCryptoHash hash { WebCryptoHash::SHA1 };
    if (*algorithm != CryptoKeyAlgorithm::RsaEsPkcs1V15) {
        const HashSpec* hash_spec = nullptr;
        if (!normalizeRsaHashedAlgorithmAfterName(
                global_object, scope, algorithm_value, algorithm_name, *algorithm, hash_spec, out_error))
            return false;
        hash = hash_spec->id;
    }

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, allowedPrivateUsagesForRsa(*algorithm), out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;

    WTF::Vector<uint8_t> bytes;
    if (!copyBufferSource(global_object, scope, key_data_value, bytes, out_error))
        return false;
    SecureVectorGuard bytes_guard(bytes);
    const uint8_t* ptr = bytes.span().data();
    const uint8_t* end = ptr + bytes.size();
    bssl::UniquePtr<PKCS8_PRIV_KEY_INFO> pkcs8(d2i_PKCS8_PRIV_KEY_INFO(nullptr, &ptr, bytes.size()));
    if (!pkcs8 || ptr != end) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKCS82PKEY(pkcs8.get()));
    if (!pkey || EVP_PKEY_id(pkey.get()) != EVP_PKEY_RSA) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createRsaKey(global_object, *algorithm, hash, CryptoKeyType::Private, WTF::move(pkey),
        extractable_value.toBoolean(global_object), usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

bool makeEcKeyFromSpki(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
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
    if (!copyBufferSource(global_object, scope, key_data_value, bytes, out_error))
        return false;
    const uint8_t* ptr = bytes.span().data();
    const uint8_t* end = ptr + bytes.size();
    bssl::UniquePtr<EVP_PKEY> pkey(d2i_PUBKEY(nullptr, &ptr, bytes.size()));
    if (!pkey || ptr != end || EVP_PKEY_id(pkey.get()) != EVP_PKEY_EC) {
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

bool makeEcKeyFromPkcs8(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
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
    if (!validateRequestedUsages(usages, allowedPrivateUsagesForEc(*algorithm), out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;

    WTF::Vector<uint8_t> bytes;
    if (!copyBufferSource(global_object, scope, key_data_value, bytes, out_error))
        return false;
    SecureVectorGuard bytes_guard(bytes);
    const uint8_t* ptr = bytes.span().data();
    const uint8_t* end = ptr + bytes.size();
    bssl::UniquePtr<PKCS8_PRIV_KEY_INFO> pkcs8(d2i_PKCS8_PRIV_KEY_INFO(nullptr, &ptr, bytes.size()));
    if (!pkcs8 || ptr != end) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKCS82PKEY(pkcs8.get()));
    if (!pkey || EVP_PKEY_id(pkey.get()) != EVP_PKEY_EC) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createEcKey(global_object, *algorithm, CryptoKeyType::Private, params.named_curve, WTF::move(pkey),
        extractable_value.toBoolean(global_object), usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

bool makeOkpKeyFromSpki(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
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
    const uint8_t* ptr = bytes.span().data();
    const uint8_t* end = ptr + bytes.size();
    bssl::UniquePtr<EVP_PKEY> pkey(d2i_PUBKEY(nullptr, &ptr, bytes.size()));
    if (!pkey || ptr != end || EVP_PKEY_id(pkey.get()) != evpTypeForOkp(*algorithm)) {
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

bool makeOkpKeyFromPkcs8(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
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
    if (!validateRequestedUsages(usages, allowedPrivateUsagesForOkp(*algorithm), out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;

    WTF::Vector<uint8_t> bytes;
    if (!copyBufferSource(global_object, scope, key_data_value, bytes, out_error))
        return false;
    SecureVectorGuard bytes_guard(bytes);
    const uint8_t* ptr = bytes.span().data();
    const uint8_t* end = ptr + bytes.size();
    bssl::UniquePtr<PKCS8_PRIV_KEY_INFO> pkcs8(d2i_PKCS8_PRIV_KEY_INFO(nullptr, &ptr, bytes.size()));
    if (!pkcs8 || ptr != end) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKCS82PKEY(pkcs8.get()));
    if (!pkey || EVP_PKEY_id(pkey.get()) != evpTypeForOkp(*algorithm)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createOkpKey(global_object, *algorithm, CryptoKeyType::Private, WTF::move(pkey),
        extractable_value.toBoolean(global_object), usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

bool exportEcRaw(
    JSC::JSGlobalObject* global_object, JSColloCryptoKey* key, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    if (key->type() != CryptoKeyType::Public) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::InvalidAccessError);
        return false;
    }
    auto* ec = EVP_PKEY_get0_EC_KEY(key->asymmetricKey());
    auto* group = ec ? EC_KEY_get0_group(ec) : nullptr;
    auto* point = ec ? EC_KEY_get0_public_key(ec) : nullptr;
    if (!group || !point) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    auto length = EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, nullptr, 0, nullptr);
    if (!length || !out.tryReserveInitialCapacity(length)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    out.grow(length);
    if (EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, out.mutableSpan().data(), out.size(), nullptr)
        != length) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool exportOkpRaw(
    JSC::JSGlobalObject* global_object, JSColloCryptoKey* key, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    if (key->type() != CryptoKeyType::Public) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::InvalidAccessError);
        return false;
    }
    if (!evpGetRawPublic(key->asymmetricKey(), out)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool exportAsymmetricSpki(
    JSC::JSGlobalObject* global_object, JSColloCryptoKey* key, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    if (key->type() != CryptoKeyType::Public) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::InvalidAccessError);
        return false;
    }
    int len = i2d_PUBKEY(key->asymmetricKey(), nullptr);
    if (len <= 0 || !out.tryReserveInitialCapacity(static_cast<size_t>(len))) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    out.grow(static_cast<size_t>(len));
    auto* ptr = out.mutableSpan().data();
    if (i2d_PUBKEY(key->asymmetricKey(), &ptr) != len) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

bool exportAsymmetricPkcs8(
    JSC::JSGlobalObject* global_object, JSColloCryptoKey* key, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    if (key->type() != CryptoKeyType::Private) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::InvalidAccessError);
        return false;
    }
    bssl::UniquePtr<PKCS8_PRIV_KEY_INFO> pkcs8(EVP_PKEY2PKCS8(key->asymmetricKey()));
    if (!pkcs8) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    int len = i2d_PKCS8_PRIV_KEY_INFO(pkcs8.get(), nullptr);
    if (len <= 0 || !out.tryReserveInitialCapacity(static_cast<size_t>(len))) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    out.grow(static_cast<size_t>(len));
    auto* ptr = out.mutableSpan().data();
    if (i2d_PKCS8_PRIV_KEY_INFO(pkcs8.get(), &ptr) != len) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    return true;
}

} // namespace Collo::HostFunctions::WebCrypto
