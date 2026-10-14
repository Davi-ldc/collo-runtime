// `SubtleCrypto.sign` and `verify` for HMAC, RSASSA-PKCS1-v1_5, RSA-PSS, ECDSA and Ed25519, run on the VM thread over
// the borrowed message and signature under a time guard (budget.h): the message is hashed in slices the guard admits,
// and the private- or public-key step after it, which nothing can interrupt, starts only once the guard admits it too.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/methods.h"

#include "host_functions/webapi/crypto/budget.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/ops/asymmetric.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "host_functions/webapi/crypto/subtle/steps.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>
#include <openssl/crypto.h>
#include <openssl/mem.h>
#include <openssl/rsa.h>

#include <array>
#include <cstring>

namespace Collo::HostFunctions {

using namespace Collo::HostFunctions::WebCrypto;
using namespace Collo::JscSupport;

namespace {

    enum class SignatureStep : uint8_t {
        Sign,
        Verify,
    };

    double signatureWorstCaseNs(
        SignatureStep step, const NormalizedAlgorithm& algorithm, JSColloCryptoKey* key, size_t data_bytes)
    {
        const bool sign = step == SignatureStep::Sign;
        switch (algorithm.id) {
        case CryptoKeyAlgorithm::Hmac:
            return hmacWorstCaseNs(key->hash(), key->material().size(), data_bytes);
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss:
            return digestWorstCaseNs(key->hash(), data_bytes)
                + (sign ? rsaPrivateWorstCaseNs(key->rsaModulusBits()) : rsaPublicWorstCaseNs(key->rsaModulusBits()));
        case CryptoKeyAlgorithm::Ecdsa:
            return digestWorstCaseNs(algorithm.paramsAs<HashParams>().hash->id, data_bytes)
                + (sign ? ecdsaSignWorstCaseNs(key->namedCurve()) : ecdsaVerifyWorstCaseNs(key->namedCurve()));
        case CryptoKeyAlgorithm::Ed25519:
            return sign ? ed25519SignWorstCaseNs(data_bytes) : ed25519VerifyWorstCaseNs(data_bytes);
        default:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    int rsaPadding(const NormalizedAlgorithm& algorithm)
    {
        return algorithm.id == CryptoKeyAlgorithm::RsaPss ? RSA_PKCS1_PSS_PADDING : RSA_PKCS1_PADDING;
    }

    uint32_t rsaSaltLength(const NormalizedAlgorithm& algorithm)
    {
        auto* params = std::get_if<RsaPssParams>(&algorithm.params);
        return params ? params->salt_length : 0;
    }

    // The message's digest for RSA and ECDSA, hashed in slices the guard admits, so that only the private- or
    // public-key step after it runs in one uninterruptible call. Holds no secret.
    struct MessageDigest {
        std::array<uint8_t, EVP_MAX_MD_SIZE> bytes;
        size_t size { 0 };

        std::span<const uint8_t> span() const { return { bytes.data(), size }; }
    };

    // Hashes `data` with `hash`, then asks `guard` for the uninterruptible step that follows, `step_ns` at worst.
    bool digestThenAdmit(
        const HashSpec& hash, std::span<const uint8_t> data, double step_ns, TimeGuard& guard, MessageDigest& out)
    {
        if (!digestBytes(hash, data, out.bytes, guard))
            return false;
        out.size = hash.digest_bytes;
        return guard.uninterruptibleFits(step_ns);
    }

    bool signData(const NormalizedAlgorithm& algorithm, JSColloCryptoKey* key, std::span<const uint8_t> data,
        SecretBytes& out, TimeGuard& guard)
    {
        MessageDigest digest;
        switch (algorithm.id) {
        case CryptoKeyAlgorithm::Hmac: {
            const auto& hash = hashSpec(key->hash());
            std::array<uint8_t, EVP_MAX_MD_SIZE> mac;
            const bool signed_data = hmacSign(hash, key->material(), data, mac, guard)
                && out.tryAppend(std::span<const uint8_t> { mac.data(), hash.digest_bytes });
            OPENSSL_cleanse(mac.data(), mac.size());
            return signed_data;
        }
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss: {
            const auto& hash = hashSpec(key->hash());
            return digestThenAdmit(hash, data, rsaPrivateWorstCaseNs(key->rsaModulusBits()), guard, digest)
                && rsaSignDigest(
                    key->pkey(), hash, digest.span(), rsaPadding(algorithm), rsaSaltLength(algorithm), out);
        }
        case CryptoKeyAlgorithm::Ecdsa:
            return digestThenAdmit(*algorithm.paramsAs<HashParams>().hash, data,
                       ecdsaSignWorstCaseNs(key->namedCurve()), guard, digest)
                && ecdsaSignDigest(key->pkey(), digest.span(), out);
        case CryptoKeyAlgorithm::Ed25519:
            return guard.uninterruptibleFits(ed25519SignWorstCaseNs(data.size()))
                && ed25519Sign(key->pkey(), data, out);
        default:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    // The comparison always covers the full expected length, whatever the signature's length, so its timing reveals
    // neither a length mismatch nor where the bytes first differ.
    bool verifyHmac(JSColloCryptoKey* key, std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out,
        TimeGuard& guard)
    {
        const auto& hash = hashSpec(key->hash());
        std::array<uint8_t, EVP_MAX_MD_SIZE> expected {};
        std::array<uint8_t, EVP_MAX_MD_SIZE> candidate {};
        const bool computed = hmacSign(hash, key->material(), data, expected, guard);
        if (computed) {
            const size_t expected_size = hash.digest_bytes;
            const size_t copy_len = signature.size() < expected_size ? signature.size() : expected_size;
            if (copy_len)
                std::memcpy(candidate.data(), signature.data(), copy_len);
            const int diff = CRYPTO_memcmp(candidate.data(), expected.data(), expected_size);
            out = (signature.size() == expected_size) & (diff == 0);
        }
        OPENSSL_cleanse(expected.data(), expected.size());
        OPENSSL_cleanse(candidate.data(), candidate.size());
        return computed;
    }

    bool verifySignature(const NormalizedAlgorithm& algorithm, JSColloCryptoKey* key,
        std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out, TimeGuard& guard)
    {
        MessageDigest digest;
        switch (algorithm.id) {
        case CryptoKeyAlgorithm::Hmac:
            return verifyHmac(key, signature, data, out, guard);
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss: {
            const auto& hash = hashSpec(key->hash());
            return digestThenAdmit(hash, data, rsaPublicWorstCaseNs(key->rsaModulusBits()), guard, digest)
                && rsaVerifyDigest(
                    key->pkey(), hash, signature, digest.span(), rsaPadding(algorithm), rsaSaltLength(algorithm), out);
        }
        case CryptoKeyAlgorithm::Ecdsa:
            return digestThenAdmit(*algorithm.paramsAs<HashParams>().hash, data,
                       ecdsaVerifyWorstCaseNs(key->namedCurve()), guard, digest)
                && ecdsaVerifyDigest(key->pkey(), signature, digest.span(), out);
        case CryptoKeyAlgorithm::Ed25519:
            return guard.uninterruptibleFits(ed25519VerifyWorstCaseNs(data.size()))
                && ed25519Verify(key->pkey(), signature, data, out);
        default:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    JSC::JSValue signatureMethod(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame, SignatureStep step)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        const bool signing = step == SignatureStep::Sign;
        // verify takes the signature before the message.
        const unsigned data_index = signing ? 2 : 3;
        checkSubtleCall(global_object, scope, call_frame, signing ? "sign"_s : "verify"_s, data_index + 1);
        RETURN_IF_EXCEPTION(scope, {});
        auto* key = requireCryptoKey(global_object, scope, call_frame->argument(1), "Expected a CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        for (unsigned index = 2; index <= data_index; ++index) {
            requireBufferSource(global_object, scope, call_frame->argument(index));
            RETURN_IF_EXCEPTION(scope, {});
        }
        auto algorithm = normalizeAlgorithm(
            global_object, scope, signing ? Operation::Sign : Operation::Verify, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        checkKey(global_object, scope, key, algorithm->id, signing ? CryptoKeyUsageSign : CryptoKeyUsageVerify);
        RETURN_IF_EXCEPTION(scope, {});

        auto data = borrowBufferSource(global_object, scope, call_frame->argument(data_index));
        RETURN_IF_EXCEPTION(scope, {});
        // Pure Ed25519 hashes the whole message inside one BoringSSL call.
        if (algorithm->id == CryptoKeyAlgorithm::Ed25519 && data->size() > single_call_input_bytes_max) {
            throwInputTooLarge(global_object, scope, "Ed25519 message"_s);
            return {};
        }
        TimeGuard guard(hostRuntimeOf(global_object));
        if (!requireStartFits(global_object, scope, guard, signatureWorstCaseNs(step, *algorithm, key, data->size())))
            return {};
        if (signing) {
            SecretBytes signature;
            if (!signData(*algorithm, key, *data, signature, guard)) {
                throwOperationFailed(global_object, scope, guard);
                return {};
            }
            RELEASE_AND_RETURN(scope, createArrayBufferCopy(global_object, scope, signature.span()));
        }
        auto signature = borrowBufferSource(global_object, scope, call_frame->argument(2));
        RETURN_IF_EXCEPTION(scope, {});
        bool valid = false;
        if (!verifySignature(*algorithm, key, *signature, *data, valid, guard)) {
            throwOperationFailed(global_object, scope, guard);
            return {};
        }
        return JSC::jsBoolean(valid);
    }

} // namespace

JSC_DEFINE_HOST_FUNCTION(subtleSign, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(
        global_object, [&] { return signatureMethod(global_object, call_frame, SignatureStep::Sign); });
}

JSC_DEFINE_HOST_FUNCTION(subtleVerify, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(
        global_object, [&] { return signatureMethod(global_object, call_frame, SignatureStep::Verify); });
}

} // namespace Collo::HostFunctions
