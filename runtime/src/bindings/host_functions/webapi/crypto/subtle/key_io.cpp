// `SubtleCrypto.importKey`, `exportKey`, `wrapKey` and `unwrapKey`. Import and export run on the VM thread and settle
// before the method returns. wrapKey exports the key there and encrypts it on the crypto pool; unwrapKey decrypts on
// the pool and imports the plaintext when the job settles (`UnwrapKeyCryptoJob`). Format parsing and serialization
// live in `key_io/`.

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

// `KeyFormat` is a WebIDL enumeration, so a value outside it fails argument conversion with a TypeError before any
// algorithm check could report NotSupportedError.
static bool isValidKeyFormat(const String& format)
{
    return format == "raw"_s || format == "spki"_s || format == "pkcs8"_s || format == "jwk"_s;
}

JSC_DEFINE_HOST_FUNCTION(subtleImportKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.importKey on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 5)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    auto format = valueToStringForPromise(global_object, scope, call_frame->argument(0), error);
    if (error)
        return rejectedPromise(global_object, error);
    if (!isValidKeyFormat(format))
        return rejectedTypeError(global_object, "Invalid KeyFormat"_s);

    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(2), algorithm_name, error))
        return rejectedPromise(global_object, error);

    JSColloCryptoKey* key = nullptr;
    if (format == "raw"_s) {
        if (WTF::equalIgnoringASCIICase(algorithm_name, "HMAC"_s)) {
            if (!makeHmacKeyFromRaw(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (aesAlgorithmFromName(algorithm_name)) {
            if (!makeAesKeyFromRaw(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (WTF::equalIgnoringASCIICase(algorithm_name, "PBKDF2"_s)) {
            if (!makeDeriveKeyFromRaw(global_object, scope, call_frame->argument(1), CryptoKeyAlgorithm::Pbkdf2,
                    call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (WTF::equalIgnoringASCIICase(algorithm_name, "HKDF"_s)) {
            if (!makeDeriveKeyFromRaw(global_object, scope, call_frame->argument(1), CryptoKeyAlgorithm::Hkdf,
                    call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (ecAlgorithmFromName(algorithm_name)) {
            if (!makeEcKeyFromRaw(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (okpAlgorithmFromName(algorithm_name)) {
            if (!makeOkpKeyFromRaw(global_object, scope, call_frame->argument(1), algorithm_name,
                    call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else
            return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    } else if (format == "spki"_s) {
        if (rsaAlgorithmFromName(algorithm_name)) {
            if (!makeRsaKeyFromSpki(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (ecAlgorithmFromName(algorithm_name)) {
            if (!makeEcKeyFromSpki(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (okpAlgorithmFromName(algorithm_name)) {
            if (!makeOkpKeyFromSpki(global_object, scope, call_frame->argument(1), algorithm_name,
                    call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else
            return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    } else if (format == "pkcs8"_s) {
        if (rsaAlgorithmFromName(algorithm_name)) {
            if (!makeRsaKeyFromPkcs8(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (ecAlgorithmFromName(algorithm_name)) {
            if (!makeEcKeyFromPkcs8(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (okpAlgorithmFromName(algorithm_name)) {
            if (!makeOkpKeyFromPkcs8(global_object, scope, call_frame->argument(1), algorithm_name,
                    call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else
            return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    } else if (format == "jwk"_s) {
        if (WTF::equalIgnoringASCIICase(algorithm_name, "HMAC"_s)) {
            if (!makeHmacKeyFromJwk(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (aesAlgorithmFromName(algorithm_name)) {
            if (!makeAesKeyFromJwk(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (rsaAlgorithmFromName(algorithm_name)) {
            if (!makeRsaKeyFromJwk(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (ecAlgorithmFromName(algorithm_name)) {
            if (!makeEcKeyFromJwk(global_object, scope, call_frame->argument(1), call_frame->argument(2),
                    algorithm_name, call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else if (okpAlgorithmFromName(algorithm_name)) {
            if (!makeOkpKeyFromJwk(global_object, scope, call_frame->argument(1), algorithm_name,
                    call_frame->argument(3), call_frame->argument(4), key, error))
                return rejectedPromise(global_object, error);
        } else
            return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    } else {
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    }
    return resolvedPromise(global_object, key);
}

JSC_DEFINE_HOST_FUNCTION(subtleExportKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.exportKey on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 2)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    auto format = valueToStringForPromise(global_object, scope, call_frame->argument(0), error);
    if (error)
        return rejectedPromise(global_object, error);
    if (!isValidKeyFormat(format))
        return rejectedTypeError(global_object, "Invalid KeyFormat"_s);

    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));
    if (key->algorithm() == CryptoKeyAlgorithm::Pbkdf2 || key->algorithm() == CryptoKeyAlgorithm::Hkdf)
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    if (!key->extractable())
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "The CryptoKey is nonextractable"_s);

    if (format == "raw"_s) {
        if (isRsaAlgorithm(key->algorithm()))
            return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
        if (isEcAlgorithm(key->algorithm())) {
            WTF::Vector<uint8_t> exported;
            SecureVectorGuard exported_guard(exported);
            if (!exportEcRaw(global_object, key, exported, error))
                return rejectedPromise(global_object, error);
            auto result = createArrayBufferCopy(global_object, scope, exported.span(), error);
            if (!result)
                return rejectedPromise(global_object, error);
            return resolvedPromise(global_object, result);
        }
        if (isOkpAlgorithm(key->algorithm())) {
            WTF::Vector<uint8_t> exported;
            SecureVectorGuard exported_guard(exported);
            if (!exportOkpRaw(global_object, key, exported, error))
                return rejectedPromise(global_object, error);
            auto result = createArrayBufferCopy(global_object, scope, exported.span(), error);
            if (!result)
                return rejectedPromise(global_object, error);
            return resolvedPromise(global_object, result);
        }
        auto result = createArrayBufferCopy(global_object, scope, key->material(), error);
        if (!result)
            return rejectedPromise(global_object, error);
        return resolvedPromise(global_object, result);
    }

    if (format == "spki"_s || format == "pkcs8"_s) {
        if (!isRsaAlgorithm(key->algorithm()) && !isEcAlgorithm(key->algorithm()) && !isOkpAlgorithm(key->algorithm()))
            return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
        WTF::Vector<uint8_t> exported;
        SecureVectorGuard exported_guard(exported);
        bool ok = format == "spki"_s ? exportAsymmetricSpki(global_object, key, exported, error)
                                     : exportAsymmetricPkcs8(global_object, key, exported, error);
        if (!ok)
            return rejectedPromise(global_object, error);
        auto result = createArrayBufferCopy(global_object, scope, exported.span(), error);
        if (!result)
            return rejectedPromise(global_object, error);
        return resolvedPromise(global_object, result);
    }

    if (format == "jwk"_s) {
        auto algorithm = key->algorithm();
        if (isRsaAlgorithm(algorithm)) {
            auto* result = createRsaJwkObject(global_object, vm, key, error);
            if (!result)
                return rejectedPromise(global_object, error);
            return resolvedPromise(global_object, result);
        }
        if (isEcAlgorithm(algorithm)) {
            auto* result = createEcJwkObject(global_object, vm, key, error);
            if (!result)
                return rejectedPromise(global_object, error);
            return resolvedPromise(global_object, result);
        }
        if (isOkpAlgorithm(algorithm)) {
            auto* result = createOkpJwkObject(global_object, vm, key, error);
            if (!result)
                return rejectedPromise(global_object, error);
            return resolvedPromise(global_object, result);
        }
        if (algorithm != CryptoKeyAlgorithm::Hmac && !isAesAlgorithm(algorithm))
            return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
        auto* result = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 5);
        result->putDirect(vm, JSC::Identifier::fromString(vm, "kty"_s), JSC::jsString(vm, String("oct"_s)));
        // `k` is the raw secret, so it is encoded through `secretBase64UrlJsString` (key_io.h), as every secret JWK
        // member must be.
        result->putDirect(vm, JSC::Identifier::fromString(vm, "k"_s), secretBase64UrlJsString(vm, key->material()));
        if (algorithm == CryptoKeyAlgorithm::Hmac) {
            const auto& spec = hashSpec(key->hash());
            if (!spec.jwk_alg.isEmpty())
                result->putDirect(
                    vm, JSC::Identifier::fromString(vm, "alg"_s), JSC::jsString(vm, String(spec.jwk_alg)));
        } else
            result->putDirect(vm, JSC::Identifier::fromString(vm, "alg"_s),
                JSC::jsString(vm, String(aesJwkAlgorithm(algorithm, key->material().size()))));
        result->putDirect(vm, JSC::Identifier::fromString(vm, "ext"_s), JSC::jsBoolean(key->extractable()));
        auto* key_ops = createUsagesArray(global_object, vm, key->usages());
        if (!key_ops) {
            if (!takePendingException(scope, error))
                error = JSC::createOutOfMemoryError(global_object);
            return rejectedPromise(global_object, error);
        }
        result->putDirect(vm, JSC::Identifier::fromString(vm, "key_ops"_s), key_ops);
        return resolvedPromise(global_object, result);
    }

    return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
}

JSC_DEFINE_HOST_FUNCTION(subtleWrapKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.wrapKey on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 4)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    auto format = valueToStringForPromise(global_object, scope, call_frame->argument(0), error);
    if (error)
        return rejectedPromise(global_object, error);
    if (!isValidKeyFormat(format))
        return rejectedTypeError(global_object, "Invalid KeyFormat"_s);

    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(1));
    if (!key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a CryptoKey"_s));

    auto* wrapping_key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(2));
    if (!wrapping_key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected a wrapping CryptoKey"_s));

    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(3), algorithm_name, error))
        return rejectedPromise(global_object, error);

    if (WTF::equalIgnoringASCIICase(algorithm_name, "RSA-OAEP"_s)) {
        RsaOaepParams params;
        if (!parseRsaOaepParamsAfterName(global_object, scope, call_frame->argument(3), algorithm_name, params, error))
            return rejectedPromise(global_object, error);
        if (wrapping_key->algorithm() != CryptoKeyAlgorithm::RsaOaep || wrapping_key->type() != CryptoKeyType::Public)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "Wrapping CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!wrapping_key->allows(CryptoKeyUsageWrapKey))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support key wrapping"_s);

        WTF::Vector<uint8_t> plaintext;
        SecureVectorGuard plaintext_guard(plaintext);
        if (!exportKeyBytesForWrap(global_object, format, key, plaintext, error))
            return rejectedPromise(global_object, error);

        auto pkey = retainSharedPkey(wrapping_key->rsaKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        const auto hash = wrapping_key->hash();
        WTF::Vector<uint8_t> label = WTF::move(params.label);
        SecureBytes plaintext_secret(WTF::move(plaintext));
        plaintext_guard.dismiss();
        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        auto job
            = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
                [pkey, hash, label = WTF::move(label), plaintext = WTF::move(plaintext_secret)](
                    WTF::Vector<uint8_t>& out) mutable {
                    return rsaOaepEncryptNative(pkey.get(), hash, label.span(), plaintext.span(), out);
                }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    auto algorithm = aesAlgorithmFromName(algorithm_name);
    if (!algorithm)
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    if (wrapping_key->algorithm() != *algorithm)
        return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
            "Wrapping CryptoKey algorithm does not match AlgorithmIdentifier"_s);
    if (!wrapping_key->allows(CryptoKeyUsageWrapKey))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support key wrapping"_s);

    AesGcmParams gcm_params;
    AesCbcParams cbc_params;
    AesCfbParams cfb_params;
    AesCtrParams ctr_params;
    switch (*algorithm) {
    case CryptoKeyAlgorithm::AesGcm:
        if (!parseAesGcmParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, gcm_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCbc:
        if (!parseAesCbcParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, cbc_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCfb:
        if (!parseAesCfbParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, cfb_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCtr:
        if (!parseAesCtrParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, ctr_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesKw:
        if (!parseAesKwParamsAfterName(global_object, algorithm_name, call_frame->argument(3), error))
            return rejectedPromise(global_object, error);
        break;
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

    WTF::Vector<uint8_t> plaintext;
    SecureVectorGuard plaintext_guard(plaintext);
    if (!exportKeyBytesForWrap(global_object, format, key, plaintext, error))
        return rejectedPromise(global_object, error);

    SecureBytes key_material;
    if (!key_material.tryAppend(wrapping_key->material()))
        return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
    SecureBytes plaintext_secret(WTF::move(plaintext));
    plaintext_guard.dismiss();

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;
    const auto selected_algorithm = *algorithm;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(context.value.owner, context.value.deferred,
        [selected_algorithm, key_material = WTF::move(key_material), plaintext = WTF::move(plaintext_secret),
            gcm_params = WTF::move(gcm_params), cbc_params = WTF::move(cbc_params), cfb_params = WTF::move(cfb_params),
            ctr_params = WTF::move(ctr_params)](WTF::Vector<uint8_t>& out) mutable {
            switch (selected_algorithm) {
            case CryptoKeyAlgorithm::AesGcm:
                return aesGcmEncrypt(key_material.span(), gcm_params, plaintext.span(), out);
            case CryptoKeyAlgorithm::AesCbc:
                return aesCbcEncrypt(key_material.span(), cbc_params, plaintext.span(), out);
            case CryptoKeyAlgorithm::AesCfb:
                return aesCfb8Encrypt(key_material.span(), cfb_params, plaintext.span(), out);
            case CryptoKeyAlgorithm::AesCtr:
                return aesCtrTransform(key_material.span(), ctr_params, plaintext.span(), out);
            case CryptoKeyAlgorithm::AesKw:
                return aesKwWrap(key_material.span(), plaintext.span(), out);
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
                return false;
            }
            return false;
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

JSC_DEFINE_HOST_FUNCTION(subtleUnwrapKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.unwrapKey on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 7)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    auto format = valueToStringForPromise(global_object, scope, call_frame->argument(0), error);
    if (error)
        return rejectedPromise(global_object, error);
    if (!isValidKeyFormat(format))
        return rejectedTypeError(global_object, "Invalid KeyFormat"_s);

    WTF::Vector<uint8_t> wrapped_bytes;
    if (!copyBufferSource(global_object, scope, call_frame->argument(1), wrapped_bytes, error))
        return rejectedPromise(global_object, error);

    auto* unwrapping_key = dynamicDowncast<JSColloCryptoKey>(call_frame->argument(2));
    if (!unwrapping_key)
        return rejectedPromise(global_object, typeErrorValue(global_object, "Expected an unwrapping CryptoKey"_s));

    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(3), algorithm_name, error))
        return rejectedPromise(global_object, error);

    if (WTF::equalIgnoringASCIICase(algorithm_name, "RSA-OAEP"_s)) {
        RsaOaepParams params;
        if (!parseRsaOaepParamsAfterName(global_object, scope, call_frame->argument(3), algorithm_name, params, error))
            return rejectedPromise(global_object, error);
        if (unwrapping_key->algorithm() != CryptoKeyAlgorithm::RsaOaep
            || unwrapping_key->type() != CryptoKeyType::Private)
            return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
                "Unwrapping CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        if (!unwrapping_key->allows(CryptoKeyUsageUnwrapKey))
            return rejectedDOMException(
                global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support key unwrapping"_s);

        WTF::Vector<uint8_t> ciphertext = WTF::move(wrapped_bytes);

        auto pkey = retainSharedPkey(unwrapping_key->rsaKey());
        if (!pkey)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        const auto hash = unwrapping_key->hash();
        WTF::Vector<uint8_t> label = WTF::move(params.label);
        UnwrappedKeyImportSpec import_spec;
        if (!normalizeUnwrappedKeyImportSpec(global_object, scope, format, call_frame->argument(4),
                call_frame->argument(5), call_frame->argument(6), import_spec, error))
            return rejectedPromise(global_object, error);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        auto job = std::unique_ptr<CryptoJob>(
            new (std::nothrow) UnwrapKeyCryptoJob(context.value.owner, context.value.deferred, format, import_spec,
                [pkey, hash, label = WTF::move(label), ciphertext = WTF::move(ciphertext)](
                    WTF::Vector<uint8_t>& out) mutable {
                    return rsaOaepDecryptNative(pkey.get(), hash, label.span(), ciphertext.span(), out);
                }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    auto algorithm = aesAlgorithmFromName(algorithm_name);
    if (!algorithm)
        return rejectedDOMException(global_object, DOMExceptionCode::NotSupportedError);
    if (unwrapping_key->algorithm() != *algorithm)
        return rejectedDOMException(global_object, DOMExceptionCode::InvalidAccessError,
            "Unwrapping CryptoKey algorithm does not match AlgorithmIdentifier"_s);
    if (!unwrapping_key->allows(CryptoKeyUsageUnwrapKey))
        return rejectedDOMException(
            global_object, DOMExceptionCode::InvalidAccessError, "CryptoKey doesn't support key unwrapping"_s);

    AesGcmParams gcm_params;
    AesCbcParams cbc_params;
    AesCfbParams cfb_params;
    AesCtrParams ctr_params;
    switch (*algorithm) {
    case CryptoKeyAlgorithm::AesGcm:
        if (!parseAesGcmParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, gcm_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCbc:
        if (!parseAesCbcParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, cbc_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCfb:
        if (!parseAesCfbParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, cfb_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesCtr:
        if (!parseAesCtrParamsAfterName(
                global_object, scope, call_frame->argument(3), algorithm_name, ctr_params, error))
            return rejectedPromise(global_object, error);
        break;
    case CryptoKeyAlgorithm::AesKw:
        if (!parseAesKwParamsAfterName(global_object, algorithm_name, call_frame->argument(3), error))
            return rejectedPromise(global_object, error);
        break;
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

    WTF::Vector<uint8_t> ciphertext = WTF::move(wrapped_bytes);

    SecureBytes key_material;
    if (!key_material.tryAppend(unwrapping_key->material()))
        return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));

    const auto selected_algorithm = *algorithm;
    UnwrappedKeyImportSpec import_spec;
    if (!normalizeUnwrappedKeyImportSpec(global_object, scope, format, call_frame->argument(4), call_frame->argument(5),
            call_frame->argument(6), import_spec, error))
        return rejectedPromise(global_object, error);

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) UnwrapKeyCryptoJob(context.value.owner,
        context.value.deferred, format, import_spec,
        [selected_algorithm, key_material = WTF::move(key_material), ciphertext = WTF::move(ciphertext),
            gcm_params = WTF::move(gcm_params), cbc_params = WTF::move(cbc_params), cfb_params = WTF::move(cfb_params),
            ctr_params = WTF::move(ctr_params)](WTF::Vector<uint8_t>& out) mutable {
            switch (selected_algorithm) {
            case CryptoKeyAlgorithm::AesGcm:
                return aesGcmDecrypt(key_material.span(), gcm_params, ciphertext.span(), out);
            case CryptoKeyAlgorithm::AesCbc:
                return aesCbcDecrypt(key_material.span(), cbc_params, ciphertext.span(), out);
            case CryptoKeyAlgorithm::AesCfb:
                return aesCfb8Decrypt(key_material.span(), cfb_params, ciphertext.span(), out);
            case CryptoKeyAlgorithm::AesCtr:
                return aesCtrTransform(key_material.span(), ctr_params, ciphertext.span(), out);
            case CryptoKeyAlgorithm::AesKw:
                return aesKwUnwrap(key_material.span(), ciphertext.span(), out);
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
                return false;
            }
            return false;
        }));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

} // namespace Collo::HostFunctions
