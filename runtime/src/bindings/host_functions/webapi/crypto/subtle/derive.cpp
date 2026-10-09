// `SubtleCrypto.deriveBits` and `deriveKey` for PBKDF2, HKDF, ECDH and X25519. Arguments are validated on the VM
// thread; a base key's bytes are copied into `SecureBytes` and the two ECDH or X25519 keys are retained through
// `retainSharedPkey`, so the derivation on the crypto pool never reads a CryptoKey cell. deriveKey builds the derived
// AES or HMAC key when its job settles (`SecretKeyCryptoJob`).

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/methods.h"

#include "host_functions/support.h"
#include "host_functions/webapi/crypto/jobs.h"
#include "host_functions/webapi/crypto/key_io/key_io.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/ops/asymmetric.h"
#include "host_functions/webapi/crypto/ops/kdf.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "host_functions/webapi/crypto/types.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSObject.h>
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <wtf/Vector.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <optional>
#include <span>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;
using namespace Collo::HostFunctions::WebCrypto;
using namespace Collo::JscSupport;

static bool validatePeerDeriveKey(JSC::JSGlobalObject* global_object, CryptoKeyAlgorithm algorithm,
    JSColloCryptoKey* private_key, JSColloCryptoKey* public_key, JSC::JSValue& out_error)
{
    if (!private_key || !public_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return false;
    }
    if (private_key->type() != CryptoKeyType::Private || public_key->type() != CryptoKeyType::Public) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::InvalidAccessError);
        return false;
    }
    if (private_key->algorithm() != algorithm || public_key->algorithm() != algorithm) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::InvalidAccessError);
        return false;
    }
    if (algorithm == CryptoKeyAlgorithm::Ecdh && private_key->namedCurve() != public_key->namedCurve()) {
        // The ECDH derive bits operation of the Web Cryptography API rejects keys on different named curves with
        // InvalidAccessError.
        out_error = domExceptionValue(global_object, DOMExceptionCode::InvalidAccessError);
        return false;
    }
    return true;
}

JSC_DEFINE_HOST_FUNCTION(subtleDeriveBits, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.deriveBits on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 3)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(0), algorithm_name, error))
        return rejectedPromise(global_object, error);

    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));

    Pbkdf2Params pbkdf2_params;
    HkdfParams hkdf_params;
    EcdhParams ecdh_params;
    X25519Params x25519_params;
    CryptoKeyAlgorithm expected_algorithm { CryptoKeyAlgorithm::Pbkdf2 };
    if (WTF::equalIgnoringASCIICase(algorithm_name, "PBKDF2"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::Pbkdf2;
        if (!parsePbkdf2ParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, pbkdf2_params, error))
            return rejectedPromise(global_object, error);
    } else if (WTF::equalIgnoringASCIICase(algorithm_name, "HKDF"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::Hkdf;
        if (!parseHkdfParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, hkdf_params, error))
            return rejectedPromise(global_object, error);
    } else if (WTF::equalIgnoringASCIICase(algorithm_name, "ECDH"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::Ecdh;
        if (!parseEcdhParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, ecdh_params, error))
            return rejectedPromise(global_object, error);
    } else if (WTF::equalIgnoringASCIICase(algorithm_name, "X25519"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::X25519;
        if (!parseX25519ParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, x25519_params, error))
            return rejectedPromise(global_object, error);
    } else
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);

    if (key->algorithm() != expected_algorithm)
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s);
    if (!key->allows(CryptoKeyUsageDeriveBits))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support bits derivation"_s);

    size_t length_bits = 0;
    if (expected_algorithm == CryptoKeyAlgorithm::Ecdh || expected_algorithm == CryptoKeyAlgorithm::X25519) {
        auto full_length_bits = expected_algorithm == CryptoKeyAlgorithm::X25519
            ? 256
            : coordinateBytesForNamedCurve(key->namedCurve()) * 8;
        if (!parseEcDeriveBitsLength(
                global_object, scope, call_frame->argument(2), full_length_bits, length_bits, error))
            return rejectedPromise(global_object, error);
    } else if (expected_algorithm == CryptoKeyAlgorithm::Pbkdf2 || expected_algorithm == CryptoKeyAlgorithm::Hkdf) {
        const auto& kdf_hash
            = expected_algorithm == CryptoKeyAlgorithm::Pbkdf2 ? *pbkdf2_params.hash : *hkdf_params.hash;
        if (!parseKdfDeriveBitsLength(
                global_object, scope, call_frame->argument(2), kdf_hash.digest_bytes * 8, length_bits, error))
            return rejectedPromise(global_object, error);
    } else if (!parseDeriveBitsLength(global_object, scope, call_frame->argument(2), length_bits, error))
        return rejectedPromise(global_object, error);

    SecureBytes base_material;
    WTF::Vector<uint8_t> salt;
    WTF::Vector<uint8_t> info;
    std::shared_ptr<EVP_PKEY> private_pkey;
    std::shared_ptr<EVP_PKEY> public_pkey;
    WebCryptoHash hash_id { WebCryptoHash::SHA256 };
    uint32_t iterations = 0;

    if (expected_algorithm == CryptoKeyAlgorithm::Pbkdf2) {
        if (!base_material.tryAppend(key->material()))
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        salt = WTF::move(pbkdf2_params.salt);
        hash_id = pbkdf2_params.hash->id;
        iterations = pbkdf2_params.iterations;
    } else if (expected_algorithm == CryptoKeyAlgorithm::Hkdf) {
        if (!base_material.tryAppend(key->material()))
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        salt = WTF::move(hkdf_params.salt);
        info = WTF::move(hkdf_params.info);
        hash_id = hkdf_params.hash->id;
    } else {
        auto* peer = expected_algorithm == CryptoKeyAlgorithm::Ecdh ? ecdh_params.public_key : x25519_params.public_key;
        if (!validatePeerDeriveKey(global_object, expected_algorithm, key, peer, error))
            return rejectedPromise(global_object, error);
        private_pkey = retainSharedPkey(key->asymmetricKey());
        public_pkey = retainSharedPkey(peer ? peer->asymmetricKey() : nullptr);
        if (!private_pkey || !public_pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);
    }

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;

    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
        [expected_algorithm, length_bits, hash_id, iterations, base_material = WTF::move(base_material),
            salt = WTF::move(salt), info = WTF::move(info), private_pkey,
            public_pkey](WTF::Vector<uint8_t>& out) mutable {
            if (expected_algorithm == CryptoKeyAlgorithm::Pbkdf2)
                return derivePbkdf2BitsNative(base_material.span(), salt.span(), iterations, hash_id, length_bits, out);
            if (expected_algorithm == CryptoKeyAlgorithm::Hkdf)
                return deriveHkdfBitsNative(base_material.span(), salt.span(), info.span(), hash_id, length_bits, out);
            if (expected_algorithm == CryptoKeyAlgorithm::Ecdh)
                return ecdhDeriveBitsNative(private_pkey.get(), public_pkey.get(), length_bits, out);
            return x25519DeriveBitsNative(private_pkey.get(), public_pkey.get(), length_bits, out);
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

JSC_DEFINE_HOST_FUNCTION(subtleDeriveKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.deriveKey on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 5)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(0), algorithm_name, error))
        return rejectedPromise(global_object, error);

    auto* base_key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!base_key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));

    Pbkdf2Params pbkdf2_params;
    HkdfParams hkdf_params;
    EcdhParams ecdh_params;
    X25519Params x25519_params;
    CryptoKeyAlgorithm expected_algorithm { CryptoKeyAlgorithm::Pbkdf2 };
    if (WTF::equalIgnoringASCIICase(algorithm_name, "PBKDF2"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::Pbkdf2;
        if (!parsePbkdf2ParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, pbkdf2_params, error))
            return rejectedPromise(global_object, error);
    } else if (WTF::equalIgnoringASCIICase(algorithm_name, "HKDF"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::Hkdf;
        if (!parseHkdfParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, hkdf_params, error))
            return rejectedPromise(global_object, error);
    } else if (WTF::equalIgnoringASCIICase(algorithm_name, "ECDH"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::Ecdh;
        if (!parseEcdhParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, ecdh_params, error))
            return rejectedPromise(global_object, error);
    } else if (WTF::equalIgnoringASCIICase(algorithm_name, "X25519"_s)) {
        expected_algorithm = CryptoKeyAlgorithm::X25519;
        if (!parseX25519ParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, x25519_params, error))
            return rejectedPromise(global_object, error);
    } else
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);

    DerivedKeySpec derived_spec;
    if (!parseDerivedKeySpec(global_object, scope, call_frame->argument(2), derived_spec, error))
        return rejectedPromise(global_object, error);

    if (base_key->algorithm() != expected_algorithm)
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s);
    if (!base_key->allows(CryptoKeyUsageDeriveKey))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support CryptoKey derivation"_s);

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, call_frame->argument(4), usages, error))
        return rejectedPromise(global_object, error);
    if (!validateRequestedUsages(usages,
            isAesAlgorithm(derived_spec.algorithm) ? allowedUsagesForAes(derived_spec.algorithm)
                                                   : CryptoKeyUsageSign | CryptoKeyUsageVerify,
            error, global_object))
        return rejectedPromise(global_object, error);
    if (!validateRequiredUsages(usages, error, global_object))
        return rejectedPromise(global_object, error);

    SecureBytes base_material;
    WTF::Vector<uint8_t> salt;
    WTF::Vector<uint8_t> info;
    std::shared_ptr<EVP_PKEY> private_pkey;
    std::shared_ptr<EVP_PKEY> public_pkey;
    WebCryptoHash hash_id { WebCryptoHash::SHA256 };
    uint32_t iterations = 0;

    if (expected_algorithm == CryptoKeyAlgorithm::Pbkdf2) {
        if (!base_material.tryAppend(base_key->material()))
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        salt = WTF::move(pbkdf2_params.salt);
        hash_id = pbkdf2_params.hash->id;
        iterations = pbkdf2_params.iterations;
    } else if (expected_algorithm == CryptoKeyAlgorithm::Hkdf) {
        if (!base_material.tryAppend(base_key->material()))
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        salt = WTF::move(hkdf_params.salt);
        info = WTF::move(hkdf_params.info);
        hash_id = hkdf_params.hash->id;
    } else {
        auto* peer = expected_algorithm == CryptoKeyAlgorithm::Ecdh ? ecdh_params.public_key : x25519_params.public_key;
        if (!validatePeerDeriveKey(global_object, expected_algorithm, base_key, peer, error))
            return rejectedPromise(global_object, error);
        private_pkey = retainSharedPkey(base_key->asymmetricKey());
        public_pkey = retainSharedPkey(peer ? peer->asymmetricKey() : nullptr);
        if (!private_pkey || !public_pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);
    }

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;

    const bool extractable = call_frame->argument(3).toBoolean(global_object);
    const auto output_algorithm = derived_spec.algorithm;
    const auto output_hash = derived_spec.hash ? derived_spec.hash->id : WebCryptoHash::SHA256;
    const size_t output_bits = derived_spec.length_bits;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) SecretKeyCryptoJob(context.value.owner,
        context.value.deferred,
        [expected_algorithm, output_algorithm, output_hash, output_bits, extractable, usages, hash_id, iterations,
            base_material = WTF::move(base_material), salt = WTF::move(salt), info = WTF::move(info), private_pkey,
            public_pkey](SecretKeyResult& result) mutable {
            result.algorithm = output_algorithm;
            result.hash = output_hash;
            result.extractable = extractable;
            result.usages = usages;
            if (expected_algorithm == CryptoKeyAlgorithm::Pbkdf2)
                return derivePbkdf2BitsNative(
                    base_material.span(), salt.span(), iterations, hash_id, output_bits, result.material.vector());
            if (expected_algorithm == CryptoKeyAlgorithm::Hkdf)
                return deriveHkdfBitsNative(
                    base_material.span(), salt.span(), info.span(), hash_id, output_bits, result.material.vector());
            if (expected_algorithm == CryptoKeyAlgorithm::Ecdh)
                return ecdhDeriveBitsNative(
                    private_pkey.get(), public_pkey.get(), output_bits, result.material.vector());
            return x25519DeriveBitsNative(private_pkey.get(), public_pkey.get(), output_bits, result.material.vector());
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

} // namespace Collo::HostFunctions
