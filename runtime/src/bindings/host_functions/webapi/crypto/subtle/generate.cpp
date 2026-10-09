// `SubtleCrypto.generateKey`. RSA, EC and OKP key pairs are generated on the crypto pool and resolve when their job
// settles (`KeyPairCryptoJob`). AES and HMAC keys draw their bytes from RAND_bytes on the VM thread and resolve before
// the method returns.

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

static bool fillCryptoRandom(std::span<uint8_t> bytes)
{
    return bytes.empty() || RAND_bytes(bytes.data(), bytes.size()) == 1;
}

// Reads a BigInteger, the Web Cryptography API's big-endian unsigned integer, allowing leading zero bytes. Null when
// it is empty or does not fit in 32 bits.
static std::optional<uint32_t> rsaExponentToUInt32(std::span<const uint8_t> exponent)
{
    if (exponent.empty())
        return std::nullopt;
    if (exponent.size() > 4) {
        for (size_t index = 0; index < exponent.size() - 4; ++index) {
            if (exponent[index])
                return std::nullopt;
        }
    }
    uint32_t result = 0;
    for (size_t index = exponent.size() > 4 ? exponent.size() - 4 : 0; index < exponent.size(); ++index) {
        result <<= 8;
        result |= exponent[index];
    }
    return result;
}

JSC_DEFINE_HOST_FUNCTION(subtleGenerateKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(
            global_object, "Can only call SubtleCrypto.generateKey on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 3)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    String algorithm_name;
    if (!algorithmName(global_object, scope, call_frame->argument(0), algorithm_name, error))
        return rejectedPromise(global_object, error);

    if (auto rsa_algorithm = rsaAlgorithmFromName(algorithm_name)) {
        uint32_t modulus_length = 0;
        WTF::Vector<uint8_t> public_exponent;
        WebCryptoHash hash { WebCryptoHash::SHA1 };
        if (*rsa_algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15) {
            RsaKeyGenParams params;
            if (!parseRsaKeyGenParamsAfterName(
                    global_object, scope, call_frame->argument(0), algorithm_name, *rsa_algorithm, params, error))
                return rejectedPromise(global_object, error);
            modulus_length = params.modulus_length;
            public_exponent = WTF::move(params.public_exponent);
        } else {
            RsaHashedKeyGenParams params;
            if (!parseRsaHashedKeyGenParamsAfterName(
                    global_object, scope, call_frame->argument(0), algorithm_name, *rsa_algorithm, params, error))
                return rejectedPromise(global_object, error);
            modulus_length = params.modulus_length;
            public_exponent = WTF::move(params.public_exponent);
            hash = params.hash->id;
        }

        uint8_t usages = 0;
        if (!parseKeyUsages(global_object, scope, call_frame->argument(2), usages, error))
            return rejectedPromise(global_object, error);
        if (!validateRequestedUsages(usages, allowedUsagesForRsa(*rsa_algorithm), error, global_object))
            return rejectedPromise(global_object, error);
        // The generateKey method steps reject a key pair whose private key would get no usages, here and for the
        // OKP and EC pairs below.
        if (!validateRequiredUsages(usages & allowedPrivateUsagesForRsa(*rsa_algorithm), error, global_object))
            return rejectedPromise(global_object, error);

        if (modulus_length < minWebCryptoRsaModulusLengthBits || modulus_length > maxWebCryptoRsaModulusLengthBits)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);
        auto exponent_value = rsaExponentToUInt32(public_exponent.span());
        if (!exponent_value || *exponent_value < 3 || !(*exponent_value & 1))
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        const auto algorithm = *rsa_algorithm;
        const bool extractable = call_frame->argument(1).toBoolean(global_object);
        auto exponent_bytes = WTF::move(public_exponent);
        auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) KeyPairCryptoJob(context.value.owner,
            context.value.deferred,
            [algorithm, hash, modulus_length, exponent_bytes = WTF::move(exponent_bytes), extractable, usages](
                KeyPairResult& result) mutable {
                auto exponent = bytesToBn(exponent_bytes.span());
                bssl::UniquePtr<RSA> private_rsa(RSA_new());
                if (!exponent || !private_rsa
                    || RSA_generate_key_ex(private_rsa.get(), static_cast<int>(modulus_length), exponent.get(), nullptr)
                        <= 0)
                    return false;
                bssl::UniquePtr<RSA> public_rsa(RSAPublicKey_dup(private_rsa.get()));
                auto public_pkey = pkeyFromRsa(public_rsa.get());
                auto private_pkey = pkeyFromRsa(private_rsa.get());
                if (!public_rsa || !public_pkey || !private_pkey)
                    return false;
                result.algorithm = algorithm;
                result.hash = hash;
                result.extractable = extractable;
                result.public_usages = usages & allowedPublicUsagesForRsa(algorithm);
                result.private_usages = usages & allowedPrivateUsagesForRsa(algorithm);
                result.public_key = WTF::move(public_pkey);
                result.private_key = WTF::move(private_pkey);
                return true;
            }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    if (auto okp_algorithm = okpAlgorithmFromName(algorithm_name)) {
        uint8_t usages = 0;
        if (!parseKeyUsages(global_object, scope, call_frame->argument(2), usages, error))
            return rejectedPromise(global_object, error);
        if (!validateRequestedUsages(usages, allowedUsagesForOkp(*okp_algorithm), error, global_object))
            return rejectedPromise(global_object, error);
        if (!validateRequiredUsages(usages & allowedPrivateUsagesForOkp(*okp_algorithm), error, global_object))
            return rejectedPromise(global_object, error);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        const auto algorithm = *okp_algorithm;
        const bool extractable = call_frame->argument(1).toBoolean(global_object);
        auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) KeyPairCryptoJob(context.value.owner,
            context.value.deferred, [algorithm, extractable, usages](KeyPairResult& result) mutable {
                bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new_id(evpTypeForOkp(algorithm), nullptr));
                EVP_PKEY* generated_raw = nullptr;
                if (!ctx || EVP_PKEY_keygen_init(ctx.get()) <= 0 || EVP_PKEY_keygen(ctx.get(), &generated_raw) <= 0)
                    return false;
                bssl::UniquePtr<EVP_PKEY> private_pkey(generated_raw);
                WTF::Vector<uint8_t> public_bytes;
                if (!evpGetRawPublic(private_pkey.get(), public_bytes))
                    return false;
                bssl::UniquePtr<EVP_PKEY> public_pkey(EVP_PKEY_new_raw_public_key(
                    evpTypeForOkp(algorithm), nullptr, public_bytes.span().data(), public_bytes.size()));
                if (!public_pkey)
                    return false;
                result.algorithm = algorithm;
                result.extractable = extractable;
                result.public_usages = usages & allowedPublicUsagesForOkp(algorithm);
                result.private_usages = usages & allowedPrivateUsagesForOkp(algorithm);
                result.public_key = WTF::move(public_pkey);
                result.private_key = WTF::move(private_pkey);
                return true;
            }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    if (auto ec_algorithm = ecAlgorithmFromName(algorithm_name)) {
        EcKeyParams params;
        if (!parseEcKeyParamsAfterName(
                global_object, scope, call_frame->argument(0), algorithm_name, *ec_algorithm, params, error))
            return rejectedPromise(global_object, error);

        uint8_t usages = 0;
        if (!parseKeyUsages(global_object, scope, call_frame->argument(2), usages, error))
            return rejectedPromise(global_object, error);
        if (!validateRequestedUsages(usages, allowedUsagesForEc(*ec_algorithm), error, global_object))
            return rejectedPromise(global_object, error);
        if (!validateRequiredUsages(usages & allowedPrivateUsagesForEc(*ec_algorithm), error, global_object))
            return rejectedPromise(global_object, error);

        auto context = createCryptoAsyncContext(global_object, scope);
        if (!context.ok)
            return context.error;
        const auto algorithm = *ec_algorithm;
        const auto curve = params.named_curve;
        const bool extractable = call_frame->argument(1).toBoolean(global_object);
        auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) KeyPairCryptoJob(context.value.owner,
            context.value.deferred, [algorithm, curve, extractable, usages](KeyPairResult& result) mutable {
                bssl::UniquePtr<EC_KEY> private_ec(EC_KEY_new_by_curve_name(nidForNamedCurve(curve)));
                if (!private_ec || EC_KEY_generate_key(private_ec.get()) != 1)
                    return false;
                bssl::UniquePtr<EC_KEY> public_ec(EC_KEY_new_by_curve_name(nidForNamedCurve(curve)));
                if (!public_ec || EC_KEY_set_public_key(public_ec.get(), EC_KEY_get0_public_key(private_ec.get())) != 1)
                    return false;
                auto public_pkey = pkeyFromEc(public_ec.get());
                auto private_pkey = pkeyFromEc(private_ec.get());
                if (!public_pkey || !private_pkey)
                    return false;
                result.algorithm = algorithm;
                result.curve = curve;
                result.extractable = extractable;
                result.public_usages = usages & allowedPublicUsagesForEc(algorithm);
                result.private_usages = usages & allowedPrivateUsagesForEc(algorithm);
                result.public_key = WTF::move(public_pkey);
                result.private_key = WTF::move(private_pkey);
                return true;
            }));
        return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
    }

    if (auto aes_algorithm = aesAlgorithmFromName(algorithm_name)) {
        auto* object = dynamicDowncast<JSC::JSObject>(call_frame->argument(0));
        if (!object)
            return rejectedPromise(
                global_object, typeErrorValue(global_object, "AES key generation requires parameters"_s));

        auto length_value = object->get(global_object, JSC::Identifier::fromString(vm, "length"_s));
        if (takePendingException(scope, error))
            return rejectedPromise(global_object, error);
        if (length_value.isUndefined())
            return rejectedPromise(global_object, typeErrorValue(global_object, "AES length is required"_s));
        double number = length_value.toNumber(global_object);
        if (takePendingException(scope, error))
            return rejectedPromise(global_object, error);
        size_t bits = 0;
        if (!checkedSizeFromNumber(number, 128, 256, bits))
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);
        if (bits != 128 && bits != 192 && bits != 256)
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        uint8_t usages = 0;
        if (!parseKeyUsages(global_object, scope, call_frame->argument(2), usages, error))
            return rejectedPromise(global_object, error);
        if (!validateRequestedUsages(usages, allowedUsagesForAes(*aes_algorithm), error, global_object))
            return rejectedPromise(global_object, error);
        if (!validateRequiredUsages(usages, error, global_object))
            return rejectedPromise(global_object, error);

        WTF::Vector<uint8_t> material;
        SecureVectorGuard material_guard(material);
        if (!material.tryReserveInitialCapacity(bits / 8))
            return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
        material.grow(bits / 8);
        if (!fillCryptoRandom(material.mutableSpan()))
            return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

        auto* key = createAesKey(global_object, *aes_algorithm, WTF::move(material),
            call_frame->argument(1).toBoolean(global_object), usages);
        if (takePendingException(scope, error))
            return rejectedPromise(global_object, error);
        if (key)
            material_guard.dismiss();
        return resolvedPromise(global_object, key);
    }

    const HashSpec* hash = nullptr;
    std::optional<size_t> length_bits;
    if (!normalizeHmacAlgorithmAfterName(
            global_object, scope, call_frame->argument(0), algorithm_name, hash, length_bits, error))
        return rejectedPromise(global_object, error);

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, call_frame->argument(2), usages, error))
        return rejectedPromise(global_object, error);
    if (!validateRequestedUsages(usages, CryptoKeyUsageSign | CryptoKeyUsageVerify, error, global_object))
        return rejectedPromise(global_object, error);
    if (!validateRequiredUsages(usages, error, global_object))
        return rejectedPromise(global_object, error);

    size_t bits = length_bits.value_or(hash->default_hmac_bits);
    if (bits == 0 || (bits % 8) != 0 || bits / 8 > maxWebCryptoGeneratedSecretBytes)
        return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

    WTF::Vector<uint8_t> material;
    SecureVectorGuard material_guard(material);
    if (!material.tryReserveInitialCapacity(bits / 8))
        return rejectedPromise(global_object, JSC::createOutOfMemoryError(global_object));
    material.grow(bits / 8);
    if (!fillCryptoRandom(material.mutableSpan()))
        return rejectedDOMException(global_object, DOMExceptionCode::OperationError);

    auto* key = createHmacKey(
        global_object, hash->id, WTF::move(material), call_frame->argument(1).toBoolean(global_object), usages);
    if (takePendingException(scope, error))
        return rejectedPromise(global_object, error);
    if (key)
        material_guard.dismiss();
    return resolvedPromise(global_object, key);
}

} // namespace Collo::HostFunctions
