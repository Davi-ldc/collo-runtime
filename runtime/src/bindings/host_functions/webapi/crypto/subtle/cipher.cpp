// `SubtleCrypto.encrypt` and `decrypt` for RSA-OAEP, RSAES-PKCS1-v1_5 and AES in the CTR, CBC, 8-bit CFB and GCM
// modes; AES-KW only wraps keys, so it rejects here with NotSupportedError. Arguments are validated and copied on the
// VM thread, a secret key's bytes into `SecureBytes` and an RSA key through `retainSharedPkey`, so the job never reads
// the CryptoKey cell from the crypto pool.

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

JSC_DEFINE_HOST_FUNCTION(subtleEncrypt, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.encrypt on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 3)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(0), algorithm_name, error))
        return rejectedPromise(global_object, error);

    if (WTF::equalIgnoringASCIICase(algorithm_name, "RSA-OAEP"_s)
        || WTF::equalIgnoringASCIICase(algorithm_name, "RSAES-PKCS1-v1_5"_s)) {
        const bool is_rsaes = WTF::equalIgnoringASCIICase(algorithm_name, "RSAES-PKCS1-v1_5"_s);
        RsaOaepParams params;
        if (!is_rsaes
            && !parseRsaOaepParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, params, error))
            return rejectedPromise(global_object, error);

        auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
        if (!key)
            return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));
        const auto expected_algorithm = is_rsaes ? CryptoKeyAlgorithm::RsaEsPkcs1V15 : CryptoKeyAlgorithm::RsaOaep;
        if (key->algorithm() != expected_algorithm || key->type() != CryptoKeyType::Public)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageEncrypt))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support encryption"_s);

        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
            return rejectedPromise(global_object, error);
        SecureBytes plaintext(WTF::move(data));

        WTF::Vector<uint8_t> label = WTF::move(params.label);
        auto pkey = retainSharedPkey(key->rsaKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);
        const auto hash = key->hash();

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        auto job
            = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
                [is_rsaes, pkey, hash, label = WTF::move(label), plaintext = WTF::move(plaintext)](
                    WTF::Vector<uint8_t>& out) mutable {
                    return is_rsaes ? rsaPkcs1EncryptNative(pkey.get(), plaintext.span(), out)
                                    : rsaOaepEncryptNative(pkey.get(), hash, label.span(), plaintext.span(), out);
                }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    auto algorithm = aesAlgorithmFromName(algorithm_name);
    if (!algorithm || *algorithm == CryptoKeyAlgorithm::AesKw)
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);

    AesGcmParams gcm_params;
    AesCbcParams cbc_params;
    AesCfbParams cfb_params;
    AesCtrParams ctr_params;
    switch (*algorithm) {
    case CryptoKeyAlgorithm::AesGcm:
        if (!parseAesGcmParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, gcm_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCbc:
        if (!parseAesCbcParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, cbc_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCfb:
        if (!parseAesCfbParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, cfb_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCtr:
        if (!parseAesCtrParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, ctr_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesKw:
    case CryptoKeyAlgorithm::Hmac:
    case CryptoKeyAlgorithm::RsaEsPkcs1V15:
    case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
    case CryptoKeyAlgorithm::RsaPss:
    case CryptoKeyAlgorithm::RsaOaep:
    case CryptoKeyAlgorithm::Ecdsa:
    case CryptoKeyAlgorithm::Ecdh:
    case CryptoKeyAlgorithm::Ed25519:
    case CryptoKeyAlgorithm::X25519:
    case CryptoKeyAlgorithm::Pbkdf2:
    case CryptoKeyAlgorithm::Hkdf:
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    }

    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));
    if (key->algorithm() != *algorithm)
        return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
            "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
    if (!key->allows(CryptoKeyUsageEncrypt))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support encryption"_s);

    WTF::Vector<uint8_t> data;
    if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
        return rejectedPromise(global_object, error);
    SecureBytes plaintext(WTF::move(data));

    SecureBytes key_material;
    if (!key_material.tryAppend(key->material()))
        return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;
    const auto selected_algorithm = *algorithm;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
        [selected_algorithm, key_material = WTF::move(key_material), gcm_params = WTF::move(gcm_params),
            cbc_params = WTF::move(cbc_params), cfb_params = WTF::move(cfb_params), ctr_params = WTF::move(ctr_params),
            plaintext = WTF::move(plaintext)](WTF::Vector<uint8_t>& out) mutable {
            switch (selected_algorithm) {
            case CryptoKeyAlgorithm::AesGcm:
                return aesGcmEncrypt(key_material.span(), gcm_params, plaintext.span(), out);
            case CryptoKeyAlgorithm::AesCbc:
                return aesCbcEncrypt(key_material.span(), cbc_params, plaintext.span(), out);
            case CryptoKeyAlgorithm::AesCfb:
                return aesCfb8Encrypt(key_material.span(), cfb_params, plaintext.span(), out);
            case CryptoKeyAlgorithm::AesCtr:
                return aesCtrTransform(key_material.span(), ctr_params, plaintext.span(), out);
            default:
                return false;
            }
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

JSC_DEFINE_HOST_FUNCTION(subtleDecrypt, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.decrypt on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 3)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(0), algorithm_name, error))
        return rejectedPromise(global_object, error);

    if (WTF::equalIgnoringASCIICase(algorithm_name, "RSA-OAEP"_s)
        || WTF::equalIgnoringASCIICase(algorithm_name, "RSAES-PKCS1-v1_5"_s)) {
        const bool is_rsaes = WTF::equalIgnoringASCIICase(algorithm_name, "RSAES-PKCS1-v1_5"_s);
        RsaOaepParams params;
        if (!is_rsaes
            && !parseRsaOaepParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, params, error))
            return rejectedPromise(global_object, error);

        auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
        if (!key)
            return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));
        const auto expected_algorithm = is_rsaes ? CryptoKeyAlgorithm::RsaEsPkcs1V15 : CryptoKeyAlgorithm::RsaOaep;
        if (key->algorithm() != expected_algorithm || key->type() != CryptoKeyType::Private)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!key->allows(CryptoKeyUsageDecrypt))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support decryption"_s);

        WTF::Vector<uint8_t> data;
        if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
            return rejectedPromise(global_object, error);

        WTF::Vector<uint8_t> label = WTF::move(params.label);
        auto pkey = retainSharedPkey(key->rsaKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);
        const auto hash = key->hash();

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        auto job
            = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
                [is_rsaes, pkey, hash, label = WTF::move(label), data = WTF::move(data)](
                    WTF::Vector<uint8_t>& out) mutable {
                    return is_rsaes ? rsaPkcs1DecryptNative(pkey.get(), data.span(), out)
                                    : rsaOaepDecryptNative(pkey.get(), hash, label.span(), data.span(), out);
                }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    auto algorithm = aesAlgorithmFromName(algorithm_name);
    if (!algorithm || *algorithm == CryptoKeyAlgorithm::AesKw)
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);

    AesGcmParams gcm_params;
    AesCbcParams cbc_params;
    AesCfbParams cfb_params;
    AesCtrParams ctr_params;
    switch (*algorithm) {
    case CryptoKeyAlgorithm::AesGcm:
        if (!parseAesGcmParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, gcm_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCbc:
        if (!parseAesCbcParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, cbc_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCfb:
        if (!parseAesCfbParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, cfb_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCtr:
        if (!parseAesCtrParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, ctr_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesKw:
    case CryptoKeyAlgorithm::Hmac:
    case CryptoKeyAlgorithm::RsaEsPkcs1V15:
    case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
    case CryptoKeyAlgorithm::RsaPss:
    case CryptoKeyAlgorithm::RsaOaep:
    case CryptoKeyAlgorithm::Ecdsa:
    case CryptoKeyAlgorithm::Ecdh:
    case CryptoKeyAlgorithm::Ed25519:
    case CryptoKeyAlgorithm::X25519:
    case CryptoKeyAlgorithm::Pbkdf2:
    case CryptoKeyAlgorithm::Hkdf:
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    }

    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));
    if (key->algorithm() != *algorithm)
        return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
            "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
    if (!key->allows(CryptoKeyUsageDecrypt))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support decryption"_s);

    WTF::Vector<uint8_t> data;
    if (!copyBufferSource(global_object, scope, call_frame->argument(2), data, error))
        return rejectedPromise(global_object, error);

    SecureBytes key_material;
    if (!key_material.tryAppend(key->material()))
        return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;
    const auto selected_algorithm = *algorithm;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
        [selected_algorithm, key_material = WTF::move(key_material), gcm_params = WTF::move(gcm_params),
            cbc_params = WTF::move(cbc_params), cfb_params = WTF::move(cfb_params), ctr_params = WTF::move(ctr_params),
            data = WTF::move(data)](WTF::Vector<uint8_t>& out) mutable {
            switch (selected_algorithm) {
            case CryptoKeyAlgorithm::AesGcm:
                return aesGcmDecrypt(key_material.span(), gcm_params, data.span(), out);
            case CryptoKeyAlgorithm::AesCbc:
                return aesCbcDecrypt(key_material.span(), cbc_params, data.span(), out);
            case CryptoKeyAlgorithm::AesCfb:
                return aesCfb8Decrypt(key_material.span(), cfb_params, data.span(), out);
            case CryptoKeyAlgorithm::AesCtr:
                return aesCtrTransform(key_material.span(), ctr_params, data.span(), out);
            default:
                return false;
            }
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

} // namespace Collo::HostFunctions
