// CryptoKey factories, key checks and BIGNUM conversions declared in keys.h, on the VM thread.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/keys.h"

#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions::WebCrypto {

namespace {

    JSC::Structure* cryptoKeyStructure(JSC::JSGlobalObject* global_object)
    {
        return uncheckedDowncast<Collo::GlobalObject>(global_object)->cryptoKeyStructure();
    }

    // Fills the RSA fields of `parts` from `pkey`; false for a key that is not RSA or whose modulus lies outside the
    // bounds.
    bool readRsaParts(EVP_PKEY* pkey, AsymmetricKeyParts& parts)
    {
        RSA* rsa = EVP_PKEY_get0_RSA(pkey);
        if (!rsa)
            return false;
        const BIGNUM* n = nullptr;
        const BIGNUM* e = nullptr;
        RSA_get0_key(rsa, &n, &e, nullptr);
        if (!n || !e)
            return false;
        const size_t modulus_bits = static_cast<size_t>(BN_num_bits(n));
        if (modulus_bits < rsa_modulus_bits_min || modulus_bits > rsa_modulus_bits_max)
            return false;
        if (!bnToBytes(e, parts.rsa_public_exponent) || parts.rsa_public_exponent.isEmpty())
            return false;
        parts.rsa_modulus_bits = modulus_bits;
        return true;
    }

    WTF::ASCIILiteral usagePhrase(CryptoKeyUsage usage)
    {
        switch (usage) {
        case CryptoKeyUsageEncrypt:
            return "encryption"_s;
        case CryptoKeyUsageDecrypt:
            return "decryption"_s;
        case CryptoKeyUsageSign:
            return "signing"_s;
        case CryptoKeyUsageVerify:
            return "verification"_s;
        case CryptoKeyUsageWrapKey:
            return "key wrapping"_s;
        case CryptoKeyUsageUnwrapKey:
            return "key unwrapping"_s;
        case CryptoKeyUsageDeriveBits:
            return "bits derivation"_s;
        case CryptoKeyUsageDeriveKey:
            return "CryptoKey derivation"_s;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

} // namespace

JSColloCryptoKey* createSecretKey(JSC::JSGlobalObject* global_object, CryptoKeyAlgorithm algorithm, WebCryptoHash hash,
    SecretBytes&& material, bool extractable, uint8_t usages, size_t hmac_length_bits)
{
    ASSERT(algorithmSpec(algorithm).secret_usages);
    return JSColloCryptoKey::createSecret(global_object->vm(), cryptoKeyStructure(global_object), algorithm, hash,
        WTF::move(material), extractable, usages, hmac_length_bits);
}

JSColloCryptoKey* createAsymmetricKey(
    JSC::JSGlobalObject* global_object, const AsymmetricKeyAttributes& attributes, bssl::UniquePtr<EVP_PKEY>& pkey)
{
    ASSERT(attributes.type != CryptoKeyType::Secret);
    if (!pkey)
        return nullptr;
    const auto& spec = algorithmSpec(attributes.algorithm);
    AsymmetricKeyParts parts;
    parts.algorithm = attributes.algorithm;
    parts.hash = attributes.hash;
    parts.type = attributes.type;
    parts.extractable = attributes.extractable;
    parts.usages = attributes.usages;
    switch (spec.family) {
    case AlgorithmFamily::Rsa:
        if (!readRsaParts(pkey.get(), parts))
            return nullptr;
        break;
    case AlgorithmFamily::Ec: {
        if (EVP_PKEY_id(pkey.get()) != EVP_PKEY_EC)
            return nullptr;
        auto curve = ecCurveFromNid(EVP_PKEY_get_ec_curve_nid(pkey.get()));
        if (!curve || *curve != attributes.named_curve)
            return nullptr;
        parts.named_curve = *curve;
        break;
    }
    case AlgorithmFamily::Okp:
        // EVP_PKEY_ED25519 and EVP_PKEY_X25519 are their curves' nids.
        if (EVP_PKEY_id(pkey.get()) != curveSpec(spec.okp_curve).nid)
            return nullptr;
        parts.named_curve = spec.okp_curve;
        break;
    case AlgorithmFamily::Hmac:
    case AlgorithmFamily::Aes:
    case AlgorithmFamily::Kdf:
        return nullptr;
    }
    parts.pkey = WTF::move(pkey);
    return JSColloCryptoKey::createAsymmetric(global_object->vm(), cryptoKeyStructure(global_object), WTF::move(parts));
}

void checkNewKeyUsages(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const AlgorithmSpec& spec,
    CryptoKeyType type, uint8_t usages)
{
    if ((usages & ~allowedUsages(spec, type)) || (type != CryptoKeyType::Public && !usages)) {
        Collo::JscSupport::throwDOMException(
            global_object, scope, DOMExceptionCode::SyntaxError, "A required parameter was missing or out-of-range"_s);
    }
}

CryptoKeyType keyTypeFor(const AlgorithmSpec& spec, CryptoKeyUsage usage)
{
    if (spec.secret_usages)
        return CryptoKeyType::Secret;
    switch (usage) {
    case CryptoKeyUsageEncrypt:
    case CryptoKeyUsageVerify:
    case CryptoKeyUsageWrapKey:
        return CryptoKeyType::Public;
    case CryptoKeyUsageDecrypt:
    case CryptoKeyUsageSign:
    case CryptoKeyUsageUnwrapKey:
    case CryptoKeyUsageDeriveBits:
    case CryptoKeyUsageDeriveKey:
        return CryptoKeyType::Private;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void checkKey(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloCryptoKey* key,
    CryptoKeyAlgorithm algorithm, CryptoKeyUsage usage)
{
    if (key->algorithm() != algorithm || key->type() != keyTypeFor(algorithmSpec(algorithm), usage)) {
        Collo::JscSupport::throwDOMException(global_object, scope, DOMExceptionCode::InvalidAccessError,
            "CryptoKey algorithm does not match AlgorithmIdentifier"_s);
        return;
    }
    if (!key->allows(usage)) {
        Collo::JscSupport::throwDOMException(global_object, scope, DOMExceptionCode::InvalidAccessError,
            WTF::makeString("CryptoKey doesn't support "_s, usagePhrase(usage)));
    }
}

bool bnToBytes(const BIGNUM* bn, WTF::Vector<uint8_t>& out)
{
    if (!bn)
        return false;
    const size_t byte_length = BN_num_bytes(bn);
    if (!out.tryReserveInitialCapacity(byte_length))
        return false;
    out.grow(byte_length);
    if (byte_length)
        BN_bn2bin(bn, out.mutableSpan().data());
    return true;
}

bool bnToBytes(const BIGNUM* bn, SecretBytes& out)
{
    if (!bn)
        return false;
    const size_t byte_length = BN_num_bytes(bn);
    if (!out.tryGrow(byte_length))
        return false;
    if (byte_length)
        BN_bn2bin(bn, out.data());
    return true;
}

bssl::UniquePtr<BIGNUM> bytesToBn(std::span<const uint8_t> bytes)
{
    if (bytes.empty())
        return nullptr;
    return bssl::UniquePtr<BIGNUM>(BN_bin2bn(bytes.data(), bytes.size(), nullptr));
}

bssl::UniquePtr<EVP_PKEY> pkeyFromRsa(RSA* rsa)
{
    if (!rsa)
        return nullptr;
    bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKEY_new());
    if (!pkey || EVP_PKEY_set1_RSA(pkey.get(), rsa) != 1)
        return nullptr;
    return pkey;
}

bssl::UniquePtr<EVP_PKEY> pkeyFromEc(EC_KEY* ec_key)
{
    if (!ec_key)
        return nullptr;
    bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKEY_new());
    if (!pkey || EVP_PKEY_set1_EC_KEY(pkey.get(), ec_key) != 1)
        return nullptr;
    return pkey;
}

}
