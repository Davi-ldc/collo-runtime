// `SubtleCrypto.sign` and `verify` for HMAC, Ed25519, ECDSA, RSASSA-PKCS1-v1_5 and RSA-PSS. Arguments are validated
// and copied on the VM thread, an HMAC key's bytes into `SecureBytes` and an asymmetric key through
// `retainSharedPkey`, and every signature or check runs on the crypto pool.

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

JSC_DEFINE_HOST_FUNCTION(subtleSign, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.sign on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 3)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(0), algorithm_name, error))
        return rejectedPromise(global_object, error);

    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));

    if (WTF::equalIgnoringASCIICase(algorithm_name, "HMAC"_s)) {
        if (key->algorithm() != CryptoKeyAlgorithm::Hmac)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageSign))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support signing"_s);

        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
            return rejectedPromise(global_object, error);

        SecureBytes key_material;
        if (!key_material.tryAppend(key->material()))
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        const auto hash = key->hash();
        auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner,
            context.value.deferred,
            [hash, key_material = WTF::move(key_material), data = WTF::move(data)](WTF::Vector<uint8_t>& out) mutable {
                std::array<uint8_t, EVP_MAX_MD_SIZE> signature;
                unsigned signature_len = 0;
                if (!hmacSign(hashSpec(hash), key_material.span(), data.span(), signature, signature_len))
                    return false;
                return out.tryAppend(std::span<const uint8_t> { signature.data(), signature_len });
            }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    if (WTF::equalIgnoringASCIICase(algorithm_name, "Ed25519"_s)) {
        if (key->algorithm() != CryptoKeyAlgorithm::Ed25519 || key->type() != CryptoKeyType::Private)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageSign))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support signing"_s);

        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
            return rejectedPromise(global_object, error);

        auto pkey = retainSharedPkey(key->asymmetricKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner,
            context.value.deferred, [pkey, data = WTF::move(data)](WTF::Vector<uint8_t>& out) mutable {
                return ed25519SignNative(pkey.get(), data.span(), out);
            }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    if (WTF::equalIgnoringASCIICase(algorithm_name, "ECDSA"_s)) {
        EcdsaParams params;
        if (!parseEcdsaParamsAfterName(global_object, scope, call_frame->argument(0), algorithm_name, params, error))
            return rejectedPromise(global_object, error);
        if (key->algorithm() != CryptoKeyAlgorithm::Ecdsa || key->type() != CryptoKeyType::Private)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageSign))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support signing"_s);

        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
            return rejectedPromise(global_object, error);

        auto pkey = retainSharedPkey(key->asymmetricKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        const auto hash = params.hash->id;
        auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner,
            context.value.deferred, [pkey, hash, data = WTF::move(data)](WTF::Vector<uint8_t>& out) mutable {
                return ecdsaSignNative(pkey.get(), hash, data.span(), out);
            }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    auto rsa_algorithm = rsaAlgorithmFromName(algorithm_name);
    if (!rsa_algorithm || *rsa_algorithm == CryptoKeyAlgorithm::RsaOaep
        || *rsa_algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15)
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);

    std::optional<uint32_t> pss_salt_length;
    if (*rsa_algorithm == CryptoKeyAlgorithm::RsaPss) {
        RsaPssParams params;
        if (!parseRsaPssParamsAfterName(global_object, scope, call_frame->argument(0), algorithm_name, params, error))
            return rejectedPromise(global_object, error);
        pss_salt_length = params.salt_length;
    }

    if (key->algorithm() != *rsa_algorithm || key->type() != CryptoKeyType::Private)
        return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
            "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
    if (!key->allows(CryptoKeyUsageSign))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support signing"_s);

    WTF::Vector<uint8_t> data;
    if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
        return rejectedPromise(global_object, error);

    auto pkey = retainSharedPkey(key->rsaKey());
    if (!pkey)
        return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;
    const auto hash = key->hash();
    int padding = *rsa_algorithm == CryptoKeyAlgorithm::RsaPss ? RSA_PKCS1_PSS_PADDING : RSA_PKCS1_PADDING;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
        [pkey, hash, padding, pss_salt_length, data = WTF::move(data)](WTF::Vector<uint8_t>& out) mutable {
            return rsaSignDigestNative(pkey.get(), hash, data.span(), padding, pss_salt_length, out);
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

JSC_DEFINE_HOST_FUNCTION(subtleVerify, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.verify on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 4)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(0), algorithm_name, error))
        return rejectedPromise(global_object, error);

    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));

    if (WTF::equalIgnoringASCIICase(algorithm_name, "HMAC"_s)) {
        if (key->algorithm() != CryptoKeyAlgorithm::Hmac)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageVerify))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support verification"_s);

        WTF::Vector<uint8_t> signature_input;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), signature_input, error))
            return rejectedPromise(global_object, error);
        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(3), data, error))
            return rejectedPromise(global_object, error);

        SecureBytes key_material;
        if (!key_material.tryAppend(key->material()))
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        const auto hash = key->hash();
        auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BoolCryptoJob(context.value.owner,
            context.value.deferred,
            [hash, key_material = WTF::move(key_material), signature_input = WTF::move(signature_input),
                data = WTF::move(data)](bool& out) mutable {
                std::array<uint8_t, EVP_MAX_MD_SIZE> expected {};
                unsigned expected_len = 0;
                if (!hmacSign(hashSpec(hash), key_material.span(), data.span(), expected, expected_len)) {
                    OPENSSL_cleanse(expected.data(), expected.size());
                    return false;
                }

                // The comparison always covers the full expected length, whatever the signature's length, so its
                // timing reveals neither a length mismatch nor where the bytes first differ.
                std::array<uint8_t, EVP_MAX_MD_SIZE> candidate {};
                const size_t expected_size = static_cast<size_t>(expected_len);
                const size_t copy_len = signature_input.size() < expected_size ? signature_input.size() : expected_size;
                if (copy_len)
                    std::memcpy(candidate.data(), signature_input.span().data(), copy_len);

                const int diff = CRYPTO_memcmp(candidate.data(), expected.data(), expected_size);
                out = (signature_input.size() == expected_size) & (diff == 0);
                OPENSSL_cleanse(expected.data(), expected.size());
                OPENSSL_cleanse(candidate.data(), candidate.size());
                return true;
            }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    if (WTF::equalIgnoringASCIICase(algorithm_name, "Ed25519"_s)) {
        if (key->algorithm() != CryptoKeyAlgorithm::Ed25519 || key->type() != CryptoKeyType::Public)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageVerify))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support verification"_s);

        WTF::Vector<uint8_t> signature_input;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), signature_input, error))
            return rejectedPromise(global_object, error);
        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(3), data, error))
            return rejectedPromise(global_object, error);

        auto pkey = retainSharedPkey(key->asymmetricKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        auto job
            = std::unique_ptr<CryptoJob>(new (std::nothrow) BoolCryptoJob(context.value.owner, context.value.deferred,
                [pkey, signature_input = WTF::move(signature_input), data = WTF::move(data)](bool& out) mutable {
                    return ed25519VerifyNative(pkey.get(), signature_input.span(), data.span(), out);
                }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    if (WTF::equalIgnoringASCIICase(algorithm_name, "ECDSA"_s)) {
        EcdsaParams params;
        if (!parseEcdsaParamsAfterName(global_object, scope, call_frame->argument(0), algorithm_name, params, error))
            return rejectedPromise(global_object, error);
        if (key->algorithm() != CryptoKeyAlgorithm::Ecdsa || key->type() != CryptoKeyType::Public)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageVerify))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support verification"_s);

        WTF::Vector<uint8_t> signature_input;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), signature_input, error))
            return rejectedPromise(global_object, error);
        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(3), data, error))
            return rejectedPromise(global_object, error);

        auto pkey = retainSharedPkey(key->asymmetricKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        const auto hash = params.hash->id;
        auto job
            = std::unique_ptr<CryptoJob>(new (std::nothrow) BoolCryptoJob(context.value.owner, context.value.deferred,
                [pkey, hash, signature_input = WTF::move(signature_input), data = WTF::move(data)](bool& out) mutable {
                    return ecdsaVerifyNative(pkey.get(), hash, signature_input.span(), data.span(), out);
                }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    auto rsa_algorithm = rsaAlgorithmFromName(algorithm_name);
    if (!rsa_algorithm || *rsa_algorithm == CryptoKeyAlgorithm::RsaOaep
        || *rsa_algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15)
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);

    std::optional<uint32_t> pss_salt_length;
    if (*rsa_algorithm == CryptoKeyAlgorithm::RsaPss) {
        RsaPssParams params;
        if (!parseRsaPssParamsAfterName(global_object, scope, call_frame->argument(0), algorithm_name, params, error))
            return rejectedPromise(global_object, error);
        pss_salt_length = params.salt_length;
    }

    if (key->algorithm() != *rsa_algorithm || key->type() != CryptoKeyType::Public)
        return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
            "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
    if (!key->allows(CryptoKeyUsageVerify))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support verification"_s);

    WTF::Vector<uint8_t> signature_input;
    if (!copyBufferSource(global_object, scope, call_frame->argument(2), signature_input, error))
        return rejectedPromise(global_object, error);
    WTF::Vector<uint8_t> data;
    if (!copyBufferSource(global_object, scope, call_frame->argument(3), data, error))
        return rejectedPromise(global_object, error);

    auto pkey = retainSharedPkey(key->rsaKey());
    if (!pkey)
        return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;
    const auto hash = key->hash();
    int padding = *rsa_algorithm == CryptoKeyAlgorithm::RsaPss ? RSA_PKCS1_PSS_PADDING : RSA_PKCS1_PADDING;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BoolCryptoJob(context.value.owner, context.value.deferred,
        [pkey, hash, padding, pss_salt_length, signature_input = WTF::move(signature_input), data = WTF::move(data)](
            bool& out) mutable {
            return rsaVerifyDigestNative(
                pkey.get(), hash, signature_input.span(), data.span(), padding, pss_salt_length, out);
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

} // namespace Collo::HostFunctions
