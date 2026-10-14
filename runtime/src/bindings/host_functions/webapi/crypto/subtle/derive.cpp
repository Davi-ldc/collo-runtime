// `SubtleCrypto.deriveBits` and `deriveKey` for PBKDF2, HKDF, ECDH and X25519, on the VM thread, through one
// derivation entry under a time guard (budget.h). deriveKey imports the derived bits as a raw AES, HMAC, PBKDF2 or HKDF
// key through the import core (key_io.h). PBKDF2's work is capped (`pbkdf2WorkNsMax` in budget.h) whatever time is
// left.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/methods.h"

#include "host_functions/webapi/crypto/budget.h"
#include "host_functions/webapi/crypto/key_io/key_io.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/ops/asymmetric.h"
#include "host_functions/webapi/crypto/ops/kdf.h"
#include "host_functions/webapi/crypto/subtle/steps.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>

#include <limits>

namespace Collo::HostFunctions {

using namespace Collo::HostFunctions::WebCrypto;
using namespace Collo::JscSupport;

namespace {

    // deriveBits' optional `length`, an unsigned long or null; undefined and a missing argument are null. Returns no
    // value with no exception for null, which each algorithm's derive bits step reads (`deriveBitsWith`). A value that
    // is not an integer within the unsigned long range is an OperationError.
    std::optional<size_t> deriveBitsLength(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        if (value.isUndefinedOrNull())
            return std::nullopt;
        double number = value.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        auto bits = integerInRange<uint32_t>(number, 0, std::numeric_limits<uint32_t>::max());
        if (!bits) {
            throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
            return std::nullopt;
        }
        return *bits;
    }

    // deriveKey's "get key length" step for the derived key, in bits. An AES or HMAC key has one; a PBKDF2 or HKDF key
    // takes every bit the derivation gives, so the step returns null, here no value with no exception.
    std::optional<size_t> derivedKeyBits(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const NormalizedAlgorithm& derived)
    {
        if (derived.spec().family == AlgorithmFamily::Kdf)
            return std::nullopt;
        if (derived.spec().family == AlgorithmFamily::Aes) {
            auto bits = integerInRange<size_t>(derived.paramsAs<AesLengthParams>().length, 128, 256);
            if (bits && (*bits == 128 || *bits == 192 || *bits == 256))
                return bits;
            throwDOMException(
                global_object, scope, DOMExceptionCode::OperationError, "Cannot get key length from derivedKeyType"_s);
            return std::nullopt;
        }
        const auto& params = derived.paramsAs<HmacParams>();
        const size_t bits = params.length_bits.value_or(params.hash->block_bits);
        if (!bits || bits / 8 > generated_secret_bytes_max) {
            JSC::throwTypeError(global_object, scope, "Cannot get key length from derivedKeyType"_s);
            return std::nullopt;
        }
        if (bits % 8) {
            throwDOMException(
                global_object, scope, DOMExceptionCode::OperationError, "Cannot get key length from derivedKeyType"_s);
            return std::nullopt;
        }
        return bits;
    }

    // ECDH and X25519 agree with the `public` key of the parameters, which must be a public key of the same algorithm
    // and, for ECDH, on the private key's curve; anything else is an InvalidAccessError.
    void checkPeerKey(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const NormalizedAlgorithm& algorithm,
        JSColloCryptoKey* private_key)
    {
        auto* public_key = algorithm.paramsAs<EcdhKeyDeriveParams>().public_key;
        if (public_key->type() != CryptoKeyType::Public || public_key->algorithm() != algorithm.id
            || public_key->namedCurve() != private_key->namedCurve())
            throwDOMException(global_object, scope, DOMExceptionCode::InvalidAccessError);
    }

    // A KDF's length: a multiple of 8 of at most `derived_bytes_max` bytes, zero included; null is an OperationError,
    // as the HKDF and PBKDF2 derive bits operations require.
    bool kdfLengthFits(std::optional<size_t> length_bits)
    {
        return length_bits && !(*length_bits % 8) && *length_bits / 8 <= derived_bytes_max;
    }

    // The derive bits step of `algorithm` for `length_bits`, no value for null, under a time guard (budget.h). HKDF and
    // PBKDF2 refuse a length `kdfLengthFits` refuses, and PBKDF2 zero iterations and work past `pbkdf2WorkNsMax`.
    // ECDH and X25519 give the whole shared secret for null and its first bits otherwise, and refuse a length past the
    // secret. Each refusal is an OperationError.
    std::optional<SecretBytes> deriveBitsWith(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const NormalizedAlgorithm& algorithm, JSColloCryptoKey* base_key, std::optional<size_t> length_bits)
    {
        TimeGuard guard(hostRuntimeOf(global_object));
        SecretBytes out;
        bool derived = false;
        switch (algorithm.id) {
        case CryptoKeyAlgorithm::Pbkdf2: {
            const auto& params = algorithm.paramsAs<Pbkdf2Params>();
            if (!kdfLengthFits(length_bits) || !params.iterations) {
                throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
                return std::nullopt;
            }
            const double work_ns = pbkdf2WorkNs(
                params.hash->id, base_key->material().size(), params.salt.size(), params.iterations, *length_bits / 8);
            if (work_ns > pbkdf2WorkNsMax()) {
                throwInputTooLarge(global_object, scope, "PBKDF2 work"_s);
                return std::nullopt;
            }
            if (!requireStartFits(global_object, scope, guard, work_ns))
                return std::nullopt;
            derived = derivePbkdf2Bits(
                base_key->material(), params.salt.span(), params.iterations, *params.hash, *length_bits, out, guard);
            break;
        }
        case CryptoKeyAlgorithm::Hkdf: {
            const auto& params = algorithm.paramsAs<HkdfParams>();
            if (!kdfLengthFits(length_bits)) {
                throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
                return std::nullopt;
            }
            const double expected_ns = hkdfWorstCaseNs(
                params.hash->id, base_key->material().size(), params.salt.size(), params.info.size(), *length_bits / 8);
            if (!requireStartFits(global_object, scope, guard, expected_ns))
                return std::nullopt;
            derived = deriveHkdfBits(
                base_key->material(), params.salt.span(), params.info.span(), *params.hash, *length_bits, out, guard);
            break;
        }
        case CryptoKeyAlgorithm::Ecdh:
        case CryptoKeyAlgorithm::X25519: {
            checkPeerKey(global_object, scope, algorithm, base_key);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            const size_t secret_bits = curveSpec(base_key->namedCurve()).coordinate_bytes * 8;
            if (length_bits && *length_bits > secret_bits) {
                throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
                return std::nullopt;
            }
            if (!requireUninterruptibleFits(
                    global_object, scope, guard, keyAgreementWorstCaseNs(base_key->namedCurve())))
                return std::nullopt;
            auto* public_key = algorithm.paramsAs<EcdhKeyDeriveParams>().public_key;
            derived = deriveSharedSecret(base_key->pkey(), public_key->pkey(), length_bits.value_or(secret_bits), out);
            break;
        }
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
        if (!derived) {
            throwOperationFailed(global_object, scope, guard);
            return std::nullopt;
        }
        return out;
    }

} // namespace

JSC_DEFINE_HOST_FUNCTION(subtleDeriveBits, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(global_object, [&]() -> JSC::JSValue {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        checkSubtleCall(global_object, scope, call_frame, "deriveBits"_s, 2);
        RETURN_IF_EXCEPTION(scope, {});
        auto* key = requireCryptoKey(global_object, scope, call_frame->argument(1), "Expected a CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto length_bits = deriveBitsLength(global_object, scope, call_frame->argument(2));
        RETURN_IF_EXCEPTION(scope, {});
        auto algorithm = normalizeAlgorithm(global_object, scope, Operation::DeriveBits, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        checkKey(global_object, scope, key, algorithm->id, CryptoKeyUsageDeriveBits);
        RETURN_IF_EXCEPTION(scope, {});
        auto bits = deriveBitsWith(global_object, scope, *algorithm, key, length_bits);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, createArrayBufferCopy(global_object, scope, bits->span()));
    });
}

JSC_DEFINE_HOST_FUNCTION(subtleDeriveKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(global_object, [&]() -> JSC::JSValue {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        checkSubtleCall(global_object, scope, call_frame, "deriveKey"_s, 5);
        RETURN_IF_EXCEPTION(scope, {});
        auto* base_key = requireCryptoKey(global_object, scope, call_frame->argument(1), "Expected a CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        const bool extractable = call_frame->argument(3).toBoolean(global_object);
        auto usages = parseKeyUsages(global_object, scope, call_frame->argument(4));
        RETURN_IF_EXCEPTION(scope, {});
        auto algorithm = normalizeAlgorithm(global_object, scope, Operation::DeriveBits, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        auto derived = normalizeAlgorithm(global_object, scope, Operation::GetKeyLength, call_frame->argument(2));
        RETURN_IF_EXCEPTION(scope, {});
        checkKey(global_object, scope, base_key, algorithm->id, CryptoKeyUsageDeriveKey);
        RETURN_IF_EXCEPTION(scope, {});
        auto length_bits = derivedKeyBits(global_object, scope, *derived);
        RETURN_IF_EXCEPTION(scope, {});
        // The import below would refuse these usages too, but only after the derivation's work.
        checkNewKeyUsages(global_object, scope, derived->spec(), CryptoKeyType::Secret, *usages);
        RETURN_IF_EXCEPTION(scope, {});

        auto bits = deriveBitsWith(global_object, scope, *algorithm, base_key, length_bits);
        RETURN_IF_EXCEPTION(scope, {});
        ImportRequest request { KeyFormat::Raw, *derived, extractable, *usages };
        auto* key = importKeyFromBytes(global_object, scope, request, WTF::move(*bits));
        RETURN_IF_EXCEPTION(scope, {});
        return key;
    });
}

} // namespace Collo::HostFunctions
