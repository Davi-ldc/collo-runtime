// Shared SubtleCrypto steps declared in steps.h, on the VM thread.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/steps.h"

#include "host_functions/webapi/crypto/budget.h"
#include "host_functions/webapi/crypto/ops/asymmetric.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <wtf/text/MakeString.h>

namespace Collo::HostFunctions::WebCrypto {

namespace {

    // The checks before a cipher runs, each throwing: the bound on an input BoringSSL handles in one call, then the
    // time guard, asked to start an operation that checks it as it goes or a step that cannot.
    bool admitCipher(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, CipherDirection direction,
        const NormalizedAlgorithm& algorithm, JSColloCryptoKey* key, size_t input_bytes, TimeGuard& guard)
    {
        switch (algorithm.id) {
        case CryptoKeyAlgorithm::AesGcm: {
            const auto& params = algorithm.paramsAs<AesGcmParams>();
            if (params.iv.size() > single_call_input_bytes_max) {
                throwInputTooLarge(global_object, scope, "AES-GCM iv"_s);
                return false;
            }
            return requireStartFits(global_object, scope, guard,
                aesGcmWorstCaseNs(input_bytes, params.additional_data.size(), params.iv.size()));
        }
        case CryptoKeyAlgorithm::AesCbc:
            return requireStartFits(global_object, scope, guard, aesWorstCaseNs(AesMode::Cbc, input_bytes));
        case CryptoKeyAlgorithm::AesCfb:
            return requireStartFits(global_object, scope, guard, aesWorstCaseNs(AesMode::Cfb8, input_bytes));
        case CryptoKeyAlgorithm::AesCtr: {
            const bool whole_block = algorithm.paramsAs<AesCtrParams>().length == 128;
            return requireStartFits(global_object, scope, guard,
                aesWorstCaseNs(whole_block ? AesMode::CtrWholeBlock : AesMode::CtrPartialBlock, input_bytes));
        }
        case CryptoKeyAlgorithm::AesKw:
            if (input_bytes > single_call_input_bytes_max) {
                throwInputTooLarge(global_object, scope, "AES-KW data"_s);
                return false;
            }
            return requireUninterruptibleFits(global_object, scope, guard, aesWorstCaseNs(AesMode::Kw, input_bytes));
        case CryptoKeyAlgorithm::RsaOaep:
        case CryptoKeyAlgorithm::RsaEsPkcs1V15: {
            // The input of an RSA cipher is bounded by the modulus; BoringSSL refuses any longer one at once.
            double worst_case_ns = direction == CipherDirection::Encrypt ? rsaPublicWorstCaseNs(key->rsaModulusBits())
                                                                         : rsaPrivateWorstCaseNs(key->rsaModulusBits());
            if (algorithm.id == CryptoKeyAlgorithm::RsaOaep) {
                const auto& label = algorithm.paramsAs<RsaOaepParams>().label;
                if (label.size() > single_call_input_bytes_max) {
                    throwInputTooLarge(global_object, scope, "RSA-OAEP label"_s);
                    return false;
                }
                worst_case_ns += digestWorstCaseNs(key->hash(), label.size());
            }
            return requireUninterruptibleFits(global_object, scope, guard, worst_case_ns);
        }
        default:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    bool cipher(CipherDirection direction, const NormalizedAlgorithm& algorithm, JSColloCryptoKey* key,
        std::span<const uint8_t> input, SecretBytes& out, TimeGuard& guard)
    {
        const bool encrypt = direction == CipherDirection::Encrypt;
        const auto material = key->material();
        switch (algorithm.id) {
        case CryptoKeyAlgorithm::AesGcm: {
            const auto& params = algorithm.paramsAs<AesGcmParams>();
            return encrypt ? aesGcmEncrypt(material, params.iv.span(), params.additional_data.span(), params.tag_bytes,
                                 input, out, guard)
                           : aesGcmDecrypt(material, params.iv.span(), params.additional_data.span(), params.tag_bytes,
                                 input, out, guard);
        }
        case CryptoKeyAlgorithm::AesCbc: {
            const auto& params = algorithm.paramsAs<AesCbcParams>();
            return encrypt ? aesCbcEncrypt(material, params.iv.span(), input, out, guard)
                           : aesCbcDecrypt(material, params.iv.span(), input, out, guard);
        }
        case CryptoKeyAlgorithm::AesCfb: {
            const auto& params = algorithm.paramsAs<AesCbcParams>();
            return encrypt ? aesCfb8Encrypt(material, params.iv.span(), input, out, guard)
                           : aesCfb8Decrypt(material, params.iv.span(), input, out, guard);
        }
        case CryptoKeyAlgorithm::AesCtr: {
            const auto& params = algorithm.paramsAs<AesCtrParams>();
            return aesCtrTransform(material, params.counter.span(), params.length, input, out, guard);
        }
        case CryptoKeyAlgorithm::AesKw:
            return encrypt ? aesKwWrap(material, input, out) : aesKwUnwrap(material, input, out);
        case CryptoKeyAlgorithm::RsaOaep: {
            const auto& params = algorithm.paramsAs<RsaOaepParams>();
            const auto& hash = hashSpec(key->hash());
            return encrypt ? rsaOaepEncrypt(key->pkey(), hash, params.label.span(), input, out)
                           : rsaOaepDecrypt(key->pkey(), hash, params.label.span(), input, out);
        }
        case CryptoKeyAlgorithm::RsaEsPkcs1V15:
            return encrypt ? rsaPkcs1Encrypt(key->pkey(), input, out) : rsaPkcs1Decrypt(key->pkey(), input, out);
        default:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

} // namespace

void checkSubtleCall(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame,
    WTF::ASCIILiteral method, unsigned required_arguments)
{
    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue())) {
        JSC::throwTypeError(global_object, scope,
            WTF::makeString("Can only call SubtleCrypto."_s, method, " on instances of SubtleCrypto"_s));
        return;
    }
    if (call_frame->argumentCount() < required_arguments)
        JSC::throwTypeError(global_object, scope, "Not enough arguments"_s);
}

JSColloCryptoKey* requireCryptoKey(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, WTF::ASCIILiteral message)
{
    auto* key = dynamicDowncast<JSColloCryptoKey>(value);
    if (!key)
        JSC::throwTypeError(global_object, scope, message);
    return key;
}

void requireBufferSource(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    if (!Collo::JscSupport::isBufferSource(value))
        JSC::throwTypeError(global_object, scope, "Expected an ArrayBuffer, TypedArray, or DataView"_s);
}

std::optional<SecretBytes> runCipher(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    CipherDirection direction, const NormalizedAlgorithm& algorithm, JSColloCryptoKey* key,
    std::span<const uint8_t> input)
{
    TimeGuard guard(hostRuntimeOf(global_object));
    if (!admitCipher(global_object, scope, direction, algorithm, key, input.size(), guard))
        return std::nullopt;
    SecretBytes out;
    if (!cipher(direction, algorithm, key, input, out, guard)) {
        throwOperationFailed(global_object, scope, guard);
        return std::nullopt;
    }
    return out;
}

}
