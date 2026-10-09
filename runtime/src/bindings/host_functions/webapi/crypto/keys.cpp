// Key family tables and CryptoKey factories declared in `keys.h`. The factories read the CryptoKey structure the
// global object caches and downcast without a check, so the global object must be a `Collo::GlobalObject`. The
// `*AlgorithmName` functions end the process for an algorithm outside their family, so a caller checks the family
// first.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/keys.h"

#include <JavaScriptCore/JSCInlines.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/nid.h>
#include <openssl/rsa.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions::WebCrypto {

using WTF::String;

std::shared_ptr<EVP_PKEY> retainSharedPkey(EVP_PKEY* key)
{
    if (!key || EVP_PKEY_up_ref(key) != 1)
        return nullptr;
    return std::shared_ptr<EVP_PKEY>(key, EVP_PKEY_free);
}

JSColloCryptoKey* createHmacKey(JSC::JSGlobalObject* global_object, WebCryptoHash hash, WTF::Vector<uint8_t>&& material,
    bool extractable, uint8_t usages, size_t declared_length_bits)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloCryptoKey::create(vm, collo_global->cryptoKeyStructure(), CryptoKeyAlgorithm::Hmac, hash,
        WTF::move(material), extractable, usages, declared_length_bits);
}

bool isAesAlgorithm(CryptoKeyAlgorithm algorithm)
{
    return algorithm == CryptoKeyAlgorithm::AesCtr || algorithm == CryptoKeyAlgorithm::AesCbc
        || algorithm == CryptoKeyAlgorithm::AesCfb || algorithm == CryptoKeyAlgorithm::AesGcm
        || algorithm == CryptoKeyAlgorithm::AesKw;
}

WTF::ASCIILiteral aesAlgorithmName(CryptoKeyAlgorithm algorithm)
{
    switch (algorithm) {
    case CryptoKeyAlgorithm::AesCtr:
        return "AES-CTR"_s;
    case CryptoKeyAlgorithm::AesCbc:
        return "AES-CBC"_s;
    case CryptoKeyAlgorithm::AesCfb:
        return "AES-CFB-8"_s;
    case CryptoKeyAlgorithm::AesGcm:
        return "AES-GCM"_s;
    case CryptoKeyAlgorithm::AesKw:
        return "AES-KW"_s;
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
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<CryptoKeyAlgorithm> aesAlgorithmFromName(const String& name)
{
    if (WTF::equalIgnoringASCIICase(name, "AES-CTR"_s))
        return CryptoKeyAlgorithm::AesCtr;
    if (WTF::equalIgnoringASCIICase(name, "AES-CBC"_s))
        return CryptoKeyAlgorithm::AesCbc;
    if (WTF::equalIgnoringASCIICase(name, "AES-CFB-8"_s) || WTF::equalIgnoringASCIICase(name, "AES-CFB"_s))
        return CryptoKeyAlgorithm::AesCfb;
    if (WTF::equalIgnoringASCIICase(name, "AES-GCM"_s))
        return CryptoKeyAlgorithm::AesGcm;
    if (WTF::equalIgnoringASCIICase(name, "AES-KW"_s))
        return CryptoKeyAlgorithm::AesKw;
    return std::nullopt;
}

JSColloCryptoKey* createAesKey(JSC::JSGlobalObject* global_object, CryptoKeyAlgorithm algorithm,
    WTF::Vector<uint8_t>&& material, bool extractable, uint8_t usages)
{
    ASSERT(isAesAlgorithm(algorithm));
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloCryptoKey::create(vm, collo_global->cryptoKeyStructure(), algorithm, WebCryptoHash::SHA256,
        WTF::move(material), extractable, usages);
}

uint8_t allowedUsagesForAes(CryptoKeyAlgorithm algorithm)
{
    ASSERT(isAesAlgorithm(algorithm));
    if (algorithm == CryptoKeyAlgorithm::AesKw)
        return CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey;
    return CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt | CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey;
}

JSColloCryptoKey* createRawDeriveKey(
    JSC::JSGlobalObject* global_object, CryptoKeyAlgorithm algorithm, WTF::Vector<uint8_t>&& material, uint8_t usages)
{
    ASSERT(algorithm == CryptoKeyAlgorithm::Pbkdf2 || algorithm == CryptoKeyAlgorithm::Hkdf);
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloCryptoKey::create(
        vm, collo_global->cryptoKeyStructure(), algorithm, WebCryptoHash::SHA256, WTF::move(material), false, usages);
}

bool isRsaAlgorithm(CryptoKeyAlgorithm algorithm)
{
    return algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15 || algorithm == CryptoKeyAlgorithm::RsaSsaPkcs1V15
        || algorithm == CryptoKeyAlgorithm::RsaPss || algorithm == CryptoKeyAlgorithm::RsaOaep;
}

WTF::ASCIILiteral rsaAlgorithmName(CryptoKeyAlgorithm algorithm)
{
    switch (algorithm) {
    case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        return "RSAES-PKCS1-v1_5"_s;
    case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        return "RSASSA-PKCS1-v1_5"_s;
    case CryptoKeyAlgorithm::RsaPss:
        return "RSA-PSS"_s;
    case CryptoKeyAlgorithm::RsaOaep:
        return "RSA-OAEP"_s;
    case CryptoKeyAlgorithm::Hmac:
    case CryptoKeyAlgorithm::AesCtr:
    case CryptoKeyAlgorithm::AesCbc:
    case CryptoKeyAlgorithm::AesCfb:
    case CryptoKeyAlgorithm::AesGcm:
    case CryptoKeyAlgorithm::AesKw:
    case CryptoKeyAlgorithm::Ecdsa:
    case CryptoKeyAlgorithm::Ecdh:
    case CryptoKeyAlgorithm::Ed25519:
    case CryptoKeyAlgorithm::X25519:
    case CryptoKeyAlgorithm::Pbkdf2:
    case CryptoKeyAlgorithm::Hkdf:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<CryptoKeyAlgorithm> rsaAlgorithmFromName(const String& name)
{
    if (WTF::equalIgnoringASCIICase(name, "RSAES-PKCS1-v1_5"_s))
        return CryptoKeyAlgorithm::RsaEsPkcs1V15;
    if (WTF::equalIgnoringASCIICase(name, "RSASSA-PKCS1-v1_5"_s))
        return CryptoKeyAlgorithm::RsaSsaPkcs1V15;
    if (WTF::equalIgnoringASCIICase(name, "RSA-PSS"_s))
        return CryptoKeyAlgorithm::RsaPss;
    if (WTF::equalIgnoringASCIICase(name, "RSA-OAEP"_s))
        return CryptoKeyAlgorithm::RsaOaep;
    return std::nullopt;
}

uint8_t allowedPublicUsagesForRsa(CryptoKeyAlgorithm algorithm)
{
    ASSERT(isRsaAlgorithm(algorithm));
    if (algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15)
        return CryptoKeyUsageEncrypt;
    if (algorithm == CryptoKeyAlgorithm::RsaOaep)
        return CryptoKeyUsageEncrypt | CryptoKeyUsageWrapKey;
    return CryptoKeyUsageVerify;
}

uint8_t allowedPrivateUsagesForRsa(CryptoKeyAlgorithm algorithm)
{
    ASSERT(isRsaAlgorithm(algorithm));
    if (algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15)
        return CryptoKeyUsageDecrypt;
    if (algorithm == CryptoKeyAlgorithm::RsaOaep)
        return CryptoKeyUsageDecrypt | CryptoKeyUsageUnwrapKey;
    return CryptoKeyUsageSign;
}

uint8_t allowedUsagesForRsa(CryptoKeyAlgorithm algorithm)
{
    return allowedPublicUsagesForRsa(algorithm) | allowedPrivateUsagesForRsa(algorithm);
}

WTF::ASCIILiteral rsaJwkAlgorithm(CryptoKeyAlgorithm algorithm, WebCryptoHash hash)
{
    switch (algorithm) {
    case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        return "RSA1_5"_s;
    case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        switch (hash) {
        case WebCryptoHash::SHA1:
            return "RS1"_s;
        case WebCryptoHash::SHA224:
            return "RS224"_s;
        case WebCryptoHash::SHA256:
            return "RS256"_s;
        case WebCryptoHash::SHA384:
            return "RS384"_s;
        case WebCryptoHash::SHA512:
            return "RS512"_s;
        case WebCryptoHash::SHA3_224:
        case WebCryptoHash::SHA3_256:
        case WebCryptoHash::SHA3_384:
        case WebCryptoHash::SHA3_512:
            return ""_s;
        }
        break;
    case CryptoKeyAlgorithm::RsaPss:
        switch (hash) {
        case WebCryptoHash::SHA1:
            return "PS1"_s;
        case WebCryptoHash::SHA224:
            return "PS224"_s;
        case WebCryptoHash::SHA256:
            return "PS256"_s;
        case WebCryptoHash::SHA384:
            return "PS384"_s;
        case WebCryptoHash::SHA512:
            return "PS512"_s;
        case WebCryptoHash::SHA3_224:
        case WebCryptoHash::SHA3_256:
        case WebCryptoHash::SHA3_384:
        case WebCryptoHash::SHA3_512:
            return ""_s;
        }
        break;
    case CryptoKeyAlgorithm::RsaOaep:
        switch (hash) {
        case WebCryptoHash::SHA1:
            return "RSA-OAEP"_s;
        case WebCryptoHash::SHA224:
            return "RSA-OAEP-224"_s;
        case WebCryptoHash::SHA256:
            return "RSA-OAEP-256"_s;
        case WebCryptoHash::SHA384:
            return "RSA-OAEP-384"_s;
        case WebCryptoHash::SHA512:
            return "RSA-OAEP-512"_s;
        case WebCryptoHash::SHA3_224:
        case WebCryptoHash::SHA3_256:
        case WebCryptoHash::SHA3_384:
        case WebCryptoHash::SHA3_512:
            return ""_s;
        }
        break;
    case CryptoKeyAlgorithm::Hmac:
    case CryptoKeyAlgorithm::AesCtr:
    case CryptoKeyAlgorithm::AesCbc:
    case CryptoKeyAlgorithm::AesCfb:
    case CryptoKeyAlgorithm::AesGcm:
    case CryptoKeyAlgorithm::AesKw:
    case CryptoKeyAlgorithm::Ecdsa:
    case CryptoKeyAlgorithm::Ecdh:
    case CryptoKeyAlgorithm::Ed25519:
    case CryptoKeyAlgorithm::X25519:
    case CryptoKeyAlgorithm::Pbkdf2:
    case CryptoKeyAlgorithm::Hkdf:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

bool bnToBytes(const BIGNUM* bn, WTF::Vector<uint8_t>& out)
{
    if (!bn)
        return false;
    auto byte_length = BN_num_bytes(bn);
    if (!out.tryReserveInitialCapacity(byte_length))
        return false;
    out.grow(byte_length);
    if (byte_length)
        BN_bn2bin(bn, out.mutableSpan().data());
    return true;
}

bssl::UniquePtr<BIGNUM> bytesToBn(std::span<const uint8_t> bytes)
{
    if (bytes.empty())
        return nullptr;
    return bssl::UniquePtr<BIGNUM>(BN_bin2bn(bytes.data(), bytes.size(), nullptr));
}

static bool rsaKeyMetadata(EVP_PKEY* pkey, size_t& out_modulus_bits, WTF::Vector<uint8_t>& out_public_exponent)
{
    RSA* rsa = EVP_PKEY_get0_RSA(pkey);
    if (!rsa)
        return false;
    const BIGNUM* n = nullptr;
    const BIGNUM* e = nullptr;
    RSA_get0_key(rsa, &n, &e, nullptr);
    if (!n || !e)
        return false;
    out_modulus_bits = static_cast<size_t>(BN_num_bits(n));
    return bnToBytes(e, out_public_exponent) && !out_public_exponent.isEmpty();
}

JSColloCryptoKey* createRsaKey(JSC::JSGlobalObject* global_object, CryptoKeyAlgorithm algorithm, WebCryptoHash hash,
    CryptoKeyType type, bssl::UniquePtr<EVP_PKEY>&& pkey, bool extractable, uint8_t usages)
{
    ASSERT(isRsaAlgorithm(algorithm));
    ASSERT(type == CryptoKeyType::Public || type == CryptoKeyType::Private);
    size_t modulus_bits = 0;
    WTF::Vector<uint8_t> public_exponent;
    if (!pkey || !rsaKeyMetadata(pkey.get(), modulus_bits, public_exponent))
        return nullptr;
    if (modulus_bits < minWebCryptoRsaModulusLengthBits || modulus_bits > maxWebCryptoRsaModulusLengthBits)
        return nullptr;

    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloCryptoKey::createRsa(vm, collo_global->cryptoKeyStructure(), algorithm, hash, type, pkey.release(),
        modulus_bits, WTF::move(public_exponent), extractable, usages);
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

bool isEcAlgorithm(CryptoKeyAlgorithm algorithm)
{
    return algorithm == CryptoKeyAlgorithm::Ecdsa || algorithm == CryptoKeyAlgorithm::Ecdh;
}

WTF::ASCIILiteral ecAlgorithmName(CryptoKeyAlgorithm algorithm)
{
    switch (algorithm) {
    case CryptoKeyAlgorithm::Ecdsa:
        return "ECDSA"_s;
    case CryptoKeyAlgorithm::Ecdh:
        return "ECDH"_s;
    case CryptoKeyAlgorithm::Hmac:
    case CryptoKeyAlgorithm::AesCtr:
    case CryptoKeyAlgorithm::AesCbc:
    case CryptoKeyAlgorithm::AesCfb:
    case CryptoKeyAlgorithm::AesGcm:
    case CryptoKeyAlgorithm::AesKw:
    case CryptoKeyAlgorithm::RsaEsPkcs1V15:
    case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
    case CryptoKeyAlgorithm::RsaPss:
    case CryptoKeyAlgorithm::RsaOaep:
    case CryptoKeyAlgorithm::Ed25519:
    case CryptoKeyAlgorithm::X25519:
    case CryptoKeyAlgorithm::Pbkdf2:
    case CryptoKeyAlgorithm::Hkdf:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<CryptoKeyAlgorithm> ecAlgorithmFromName(const String& name)
{
    if (WTF::equalIgnoringASCIICase(name, "ECDSA"_s))
        return CryptoKeyAlgorithm::Ecdsa;
    if (WTF::equalIgnoringASCIICase(name, "ECDH"_s))
        return CryptoKeyAlgorithm::Ecdh;
    return std::nullopt;
}

WTF::ASCIILiteral namedCurveName(CryptoKeyNamedCurve curve)
{
    switch (curve) {
    case CryptoKeyNamedCurve::P256:
        return "P-256"_s;
    case CryptoKeyNamedCurve::P384:
        return "P-384"_s;
    case CryptoKeyNamedCurve::P521:
        return "P-521"_s;
    case CryptoKeyNamedCurve::Ed25519:
        return "Ed25519"_s;
    case CryptoKeyNamedCurve::X25519:
        return "X25519"_s;
    case CryptoKeyNamedCurve::None:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<CryptoKeyNamedCurve> namedCurveFromName(const String& name)
{
    if (WTF::equalIgnoringASCIICase(name, "P-256"_s))
        return CryptoKeyNamedCurve::P256;
    if (WTF::equalIgnoringASCIICase(name, "P-384"_s))
        return CryptoKeyNamedCurve::P384;
    if (WTF::equalIgnoringASCIICase(name, "P-521"_s))
        return CryptoKeyNamedCurve::P521;
    return std::nullopt;
}

int nidForNamedCurve(CryptoKeyNamedCurve curve)
{
    switch (curve) {
    case CryptoKeyNamedCurve::P256:
        return NID_X9_62_prime256v1;
    case CryptoKeyNamedCurve::P384:
        return NID_secp384r1;
    case CryptoKeyNamedCurve::P521:
        return NID_secp521r1;
    case CryptoKeyNamedCurve::Ed25519:
    case CryptoKeyNamedCurve::X25519:
    case CryptoKeyNamedCurve::None:
        break;
    }
    return NID_undef;
}

std::optional<CryptoKeyNamedCurve> namedCurveFromNid(int nid)
{
    switch (nid) {
    case NID_X9_62_prime256v1:
        return CryptoKeyNamedCurve::P256;
    case NID_secp384r1:
        return CryptoKeyNamedCurve::P384;
    case NID_secp521r1:
        return CryptoKeyNamedCurve::P521;
    default:
        return std::nullopt;
    }
}

size_t coordinateBytesForNamedCurve(CryptoKeyNamedCurve curve)
{
    switch (curve) {
    case CryptoKeyNamedCurve::P256:
        return 32;
    case CryptoKeyNamedCurve::P384:
        return 48;
    case CryptoKeyNamedCurve::P521:
        return 66;
    case CryptoKeyNamedCurve::Ed25519:
    case CryptoKeyNamedCurve::X25519:
    case CryptoKeyNamedCurve::None:
        break;
    }
    return 0;
}

uint8_t allowedPublicUsagesForEc(CryptoKeyAlgorithm algorithm)
{
    return algorithm == CryptoKeyAlgorithm::Ecdsa ? CryptoKeyUsageVerify : 0;
}

uint8_t allowedPrivateUsagesForEc(CryptoKeyAlgorithm algorithm)
{
    return algorithm == CryptoKeyAlgorithm::Ecdsa ? CryptoKeyUsageSign
                                                  : (CryptoKeyUsageDeriveBits | CryptoKeyUsageDeriveKey);
}

uint8_t allowedUsagesForEc(CryptoKeyAlgorithm algorithm)
{
    return allowedPublicUsagesForEc(algorithm) | allowedPrivateUsagesForEc(algorithm);
}

static bool ecKeyMetadata(EVP_PKEY* pkey, CryptoKeyNamedCurve& out_curve)
{
    if (!pkey || EVP_PKEY_id(pkey) != EVP_PKEY_EC)
        return false;
    auto curve = namedCurveFromNid(EVP_PKEY_get_ec_curve_nid(pkey));
    if (!curve)
        return false;
    out_curve = *curve;
    return true;
}

JSColloCryptoKey* createEcKey(JSC::JSGlobalObject* global_object, CryptoKeyAlgorithm algorithm, CryptoKeyType type,
    CryptoKeyNamedCurve curve, bssl::UniquePtr<EVP_PKEY>&& pkey, bool extractable, uint8_t usages)
{
    ASSERT(isEcAlgorithm(algorithm));
    ASSERT(type == CryptoKeyType::Public || type == CryptoKeyType::Private);
    CryptoKeyNamedCurve key_curve { CryptoKeyNamedCurve::None };
    if (!pkey || !ecKeyMetadata(pkey.get(), key_curve) || key_curve != curve)
        return nullptr;

    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloCryptoKey::createEc(
        vm, collo_global->cryptoKeyStructure(), algorithm, curve, type, pkey.release(), extractable, usages);
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

bool isOkpAlgorithm(CryptoKeyAlgorithm algorithm)
{
    return algorithm == CryptoKeyAlgorithm::Ed25519 || algorithm == CryptoKeyAlgorithm::X25519;
}

WTF::ASCIILiteral okpAlgorithmName(CryptoKeyAlgorithm algorithm)
{
    switch (algorithm) {
    case CryptoKeyAlgorithm::Ed25519:
        return "Ed25519"_s;
    case CryptoKeyAlgorithm::X25519:
        return "X25519"_s;
    case CryptoKeyAlgorithm::Hmac:
    case CryptoKeyAlgorithm::AesCtr:
    case CryptoKeyAlgorithm::AesCbc:
    case CryptoKeyAlgorithm::AesCfb:
    case CryptoKeyAlgorithm::AesGcm:
    case CryptoKeyAlgorithm::AesKw:
    case CryptoKeyAlgorithm::RsaEsPkcs1V15:
    case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
    case CryptoKeyAlgorithm::RsaPss:
    case CryptoKeyAlgorithm::RsaOaep:
    case CryptoKeyAlgorithm::Ecdsa:
    case CryptoKeyAlgorithm::Ecdh:
    case CryptoKeyAlgorithm::Pbkdf2:
    case CryptoKeyAlgorithm::Hkdf:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<CryptoKeyAlgorithm> okpAlgorithmFromName(const String& name)
{
    if (WTF::equalIgnoringASCIICase(name, "Ed25519"_s))
        return CryptoKeyAlgorithm::Ed25519;
    if (WTF::equalIgnoringASCIICase(name, "X25519"_s))
        return CryptoKeyAlgorithm::X25519;
    return std::nullopt;
}

CryptoKeyNamedCurve okpCurveForAlgorithm(CryptoKeyAlgorithm algorithm)
{
    ASSERT(isOkpAlgorithm(algorithm));
    return algorithm == CryptoKeyAlgorithm::Ed25519 ? CryptoKeyNamedCurve::Ed25519 : CryptoKeyNamedCurve::X25519;
}

int evpTypeForOkp(CryptoKeyAlgorithm algorithm)
{
    ASSERT(isOkpAlgorithm(algorithm));
    return algorithm == CryptoKeyAlgorithm::Ed25519 ? EVP_PKEY_ED25519 : EVP_PKEY_X25519;
}

uint8_t allowedPublicUsagesForOkp(CryptoKeyAlgorithm algorithm)
{
    ASSERT(isOkpAlgorithm(algorithm));
    return algorithm == CryptoKeyAlgorithm::Ed25519 ? CryptoKeyUsageVerify : 0;
}

uint8_t allowedPrivateUsagesForOkp(CryptoKeyAlgorithm algorithm)
{
    ASSERT(isOkpAlgorithm(algorithm));
    return algorithm == CryptoKeyAlgorithm::Ed25519 ? CryptoKeyUsageSign
                                                    : (CryptoKeyUsageDeriveBits | CryptoKeyUsageDeriveKey);
}

uint8_t allowedUsagesForOkp(CryptoKeyAlgorithm algorithm)
{
    return allowedPublicUsagesForOkp(algorithm) | allowedPrivateUsagesForOkp(algorithm);
}

static bool okpKeyMetadata(EVP_PKEY* pkey, CryptoKeyAlgorithm algorithm)
{
    return pkey && EVP_PKEY_id(pkey) == evpTypeForOkp(algorithm);
}

JSColloCryptoKey* createOkpKey(JSC::JSGlobalObject* global_object, CryptoKeyAlgorithm algorithm, CryptoKeyType type,
    bssl::UniquePtr<EVP_PKEY>&& pkey, bool extractable, uint8_t usages)
{
    ASSERT(isOkpAlgorithm(algorithm));
    ASSERT(type == CryptoKeyType::Public || type == CryptoKeyType::Private);
    if (!okpKeyMetadata(pkey.get(), algorithm))
        return nullptr;

    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloCryptoKey::createOkp(vm, collo_global->cryptoKeyStructure(), algorithm,
        okpCurveForAlgorithm(algorithm), type, pkey.release(), extractable, usages);
}

}
