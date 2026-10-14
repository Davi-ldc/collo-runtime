// The byte-format import core and the import usage rule, under the contract in key_io.h. A raw import takes the bytes
// of a secret key, which the new CryptoKey keeps, or an EC or OKP public key. An spki or pkcs8 import accepts the DER
// only when BoringSSL parses it to its end as the one key type the algorithm names, an RSA key or a key on the named
// curve; anything else is a DataError.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/key_io/key_io.h"

#include "host_functions/webapi/crypto/algorithms.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions::WebCrypto {

using Collo::JscSupport::throwDOMException;

namespace {

    void throwDataError(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        throwDOMException(global_object, scope, DOMExceptionCode::DataError);
    }

    // Takes `pkey` into a CryptoKey, or throws a DataError when it does not fit the request.
    JSColloCryptoKey* createImportedKey(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const ImportRequest& request, CryptoKeyType type, CryptoKeyNamedCurve curve, bssl::UniquePtr<EVP_PKEY>& pkey)
    {
        auto* key = createAsymmetricKey(global_object,
            { request.algorithm.id, importedRsaHash(request.algorithm), curve, type, request.extractable,
                request.usages },
            pkey);
        if (!key)
            throwDataError(global_object, scope);
        return key;
    }

    // The curve an EC or OKP key the request imports must be on; None for RSA.
    CryptoKeyNamedCurve importedCurve(const ImportRequest& request)
    {
        const auto& spec = request.algorithm.spec();
        if (spec.family == AlgorithmFamily::Ec)
            return request.algorithm.paramsAs<EcKeyParams>().named_curve;
        return spec.okp_curve;
    }

    JSColloCryptoKey* importRawSecret(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ImportRequest& request, SecretBytes&& bytes)
    {
        const auto& spec = request.algorithm.spec();
        checkNewKeyUsages(global_object, scope, spec, CryptoKeyType::Secret, request.usages);
        RETURN_IF_EXCEPTION(scope, nullptr);
        switch (spec.family) {
        case AlgorithmFamily::Hmac: {
            const auto& params = request.algorithm.paramsAs<HmacParams>();
            if (bytes.isEmpty() || !hmacLengthFits(params.length_bits, bytes.size())) {
                throwDataError(global_object, scope);
                return nullptr;
            }
            return createSecretKey(global_object, spec.id, params.hash->id, WTF::move(bytes), request.extractable,
                request.usages, params.length_bits.value_or(0));
        }
        case AlgorithmFamily::Aes:
            // An AES import takes a plain Algorithm dictionary, so the key's length is the data's.
            if (!isValidAesKeyLength(bytes.size())) {
                throwDataError(global_object, scope);
                return nullptr;
            }
            return createSecretKey(
                global_object, spec.id, WebCryptoHash::SHA256, WTF::move(bytes), request.extractable, request.usages);
        case AlgorithmFamily::Kdf:
            // A PBKDF2 or HKDF key is never extractable.
            if (request.extractable) {
                throwDOMException(global_object, scope, DOMExceptionCode::SyntaxError,
                    "A required parameter was missing or out-of-range"_s);
                return nullptr;
            }
            return createSecretKey(
                global_object, spec.id, WebCryptoHash::SHA256, WTF::move(bytes), false, request.usages);
        case AlgorithmFamily::Rsa:
        case AlgorithmFamily::Ec:
        case AlgorithmFamily::Okp:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    JSColloCryptoKey* importRawPublic(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const ImportRequest& request, std::span<const uint8_t> bytes)
    {
        const auto& spec = request.algorithm.spec();
        checkNewKeyUsages(global_object, scope, spec, CryptoKeyType::Public, request.usages);
        RETURN_IF_EXCEPTION(scope, nullptr);
        const auto curve = importedCurve(request);
        const auto& curve_spec = curveSpec(curve);
        bssl::UniquePtr<EVP_PKEY> pkey;
        if (spec.family == AlgorithmFamily::Okp) {
            if (bytes.size() == curve_spec.coordinate_bytes)
                pkey.reset(EVP_PKEY_new_raw_public_key(curve_spec.nid, nullptr, bytes.data(), bytes.size()));
        } else {
            // Only the uncompressed point, 0x04 and both affine coordinates: the Web Cryptography API requires that
            // form and lets an implementation refuse compressed points, which EC_POINT_oct2point would decode.
            const bool uncompressed = bytes.size() == 1 + 2 * curve_spec.coordinate_bytes && bytes[0] == 0x04;
            bssl::UniquePtr<EC_KEY> ec(uncompressed ? EC_KEY_new_by_curve_name(curve_spec.nid) : nullptr);
            auto* group = ec ? EC_KEY_get0_group(ec.get()) : nullptr;
            bssl::UniquePtr<EC_POINT> point(group ? EC_POINT_new(group) : nullptr);
            if (point && EC_POINT_oct2point(group, point.get(), bytes.data(), bytes.size(), nullptr) == 1
                && EC_KEY_set_public_key(ec.get(), point.get()) == 1 && EC_KEY_check_key(ec.get()) == 1)
                pkey = pkeyFromEc(ec.get());
        }
        return createImportedKey(global_object, scope, request, CryptoKeyType::Public, curve, pkey);
    }

    // An spki or pkcs8 import of an RSA, EC or OKP key.
    JSColloCryptoKey* importDer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const ImportRequest& request, std::span<const uint8_t> bytes)
    {
        const auto& spec = request.algorithm.spec();
        const auto type = request.format == KeyFormat::Spki ? CryptoKeyType::Public : CryptoKeyType::Private;
        checkNewKeyUsages(global_object, scope, spec, type, request.usages);
        RETURN_IF_EXCEPTION(scope, nullptr);
        const auto curve = spec.family == AlgorithmFamily::Rsa ? CryptoKeyNamedCurve::None : importedCurve(request);
        const EVP_PKEY_ALG* key_type
            = curve == CryptoKeyNamedCurve::None ? EVP_pkey_rsa() : curveSpec(curve).pkey_alg();
        bssl::UniquePtr<EVP_PKEY> pkey(type == CryptoKeyType::Public
                ? EVP_PKEY_from_subject_public_key_info(bytes.data(), bytes.size(), &key_type, 1)
                : EVP_PKEY_from_private_key_info(bytes.data(), bytes.size(), &key_type, 1));
        return createImportedKey(global_object, scope, request, type, curve, pkey);
    }

} // namespace

JSColloCryptoKey* importKeyFromBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ImportRequest& request, SecretBytes&& bytes)
{
    const auto family = request.algorithm.spec().family;
    const bool secret
        = family == AlgorithmFamily::Hmac || family == AlgorithmFamily::Aes || family == AlgorithmFamily::Kdf;
    switch (request.format) {
    case KeyFormat::Raw:
        if (secret)
            return importRawSecret(global_object, scope, request, WTF::move(bytes));
        if (family != AlgorithmFamily::Rsa)
            return importRawPublic(global_object, scope, request, bytes.span());
        break;
    case KeyFormat::Spki:
    case KeyFormat::Pkcs8:
        if (!secret)
            return importDer(global_object, scope, request, bytes.span());
        break;
    case KeyFormat::Jwk:
        RELEASE_ASSERT_NOT_REACHED();
    }
    throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError);
    return nullptr;
}

}
