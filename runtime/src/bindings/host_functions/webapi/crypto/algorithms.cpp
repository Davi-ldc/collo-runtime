// The constant tables declared in algorithms.h. Each table indexed by an enumeration holds its entries in that
// enumeration's order, which a static_assert checks, so a lookup is an array index.

#include "host_functions/webapi/crypto/algorithms.h"

#include <openssl/evp.h>
#include <openssl/nid.h>
#include <wtf/Assertions.h>
#include <wtf/text/WTFString.h>

#include <array>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    constexpr uint8_t aes_cipher_usages
        = CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt | CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey;
    constexpr uint8_t sign_usages = CryptoKeyUsageSign | CryptoKeyUsageVerify;
    constexpr uint8_t derive_usages = CryptoKeyUsageDeriveBits | CryptoKeyUsageDeriveKey;

    constexpr std::array allAlgorithmSpecs {
        AlgorithmSpec { CryptoKeyAlgorithm::Hmac, "HMAC"_s, ""_s, AlgorithmFamily::Hmac, sign_usages, 0, 0,
            CryptoKeyNamedCurve::None, "sig"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::AesCtr, "AES-CTR"_s, ""_s, AlgorithmFamily::Aes, aes_cipher_usages, 0, 0,
            CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::AesCbc, "AES-CBC"_s, ""_s, AlgorithmFamily::Aes, aes_cipher_usages, 0, 0,
            CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::AesCfb, "AES-CFB-8"_s, "AES-CFB"_s, AlgorithmFamily::Aes, aes_cipher_usages,
            0, 0, CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::AesGcm, "AES-GCM"_s, ""_s, AlgorithmFamily::Aes, aes_cipher_usages, 0, 0,
            CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::AesKw, "AES-KW"_s, ""_s, AlgorithmFamily::Aes,
            CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey, 0, 0, CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::RsaEsPkcs1V15, "RSAES-PKCS1-v1_5"_s, ""_s, AlgorithmFamily::Rsa, 0,
            CryptoKeyUsageEncrypt, CryptoKeyUsageDecrypt, CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::RsaSsaPkcs1V15, "RSASSA-PKCS1-v1_5"_s, ""_s, AlgorithmFamily::Rsa, 0,
            CryptoKeyUsageVerify, CryptoKeyUsageSign, CryptoKeyNamedCurve::None, "sig"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::RsaPss, "RSA-PSS"_s, ""_s, AlgorithmFamily::Rsa, 0, CryptoKeyUsageVerify,
            CryptoKeyUsageSign, CryptoKeyNamedCurve::None, "sig"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::RsaOaep, "RSA-OAEP"_s, ""_s, AlgorithmFamily::Rsa, 0,
            CryptoKeyUsageEncrypt | CryptoKeyUsageWrapKey, CryptoKeyUsageDecrypt | CryptoKeyUsageUnwrapKey,
            CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::Ecdsa, "ECDSA"_s, ""_s, AlgorithmFamily::Ec, 0, CryptoKeyUsageVerify,
            CryptoKeyUsageSign, CryptoKeyNamedCurve::None, "sig"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::Ecdh, "ECDH"_s, ""_s, AlgorithmFamily::Ec, 0, 0, derive_usages,
            CryptoKeyNamedCurve::None, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::Ed25519, "Ed25519"_s, ""_s, AlgorithmFamily::Okp, 0, CryptoKeyUsageVerify,
            CryptoKeyUsageSign, CryptoKeyNamedCurve::Ed25519, "sig"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::X25519, "X25519"_s, ""_s, AlgorithmFamily::Okp, 0, 0, derive_usages,
            CryptoKeyNamedCurve::X25519, "enc"_s },
        AlgorithmSpec { CryptoKeyAlgorithm::Pbkdf2, "PBKDF2"_s, ""_s, AlgorithmFamily::Kdf, derive_usages, 0, 0,
            CryptoKeyNamedCurve::None, ""_s },
        AlgorithmSpec { CryptoKeyAlgorithm::Hkdf, "HKDF"_s, ""_s, AlgorithmFamily::Kdf, derive_usages, 0, 0,
            CryptoKeyNamedCurve::None, ""_s },
    };

    // An algorithm missing from an operation's rows is NotSupportedError for that operation. AES-KW is registered for
    // wrapKey and unwrapKey alone; the AES modes and RSA-OAEP wrap through their encrypt parameters, and
    // RSAES-PKCS1-v1_5, which Collo keeps beyond the Web Cryptography API, encrypts but never wraps.
    constexpr std::array allRegistrations {
        Registration { Operation::Encrypt, CryptoKeyAlgorithm::RsaEsPkcs1V15, ParamsKind::None },
        Registration { Operation::Encrypt, CryptoKeyAlgorithm::RsaOaep, ParamsKind::RsaOaep },
        Registration { Operation::Encrypt, CryptoKeyAlgorithm::AesCtr, ParamsKind::AesCtr },
        Registration { Operation::Encrypt, CryptoKeyAlgorithm::AesCbc, ParamsKind::AesCbc },
        Registration { Operation::Encrypt, CryptoKeyAlgorithm::AesCfb, ParamsKind::AesCbc },
        Registration { Operation::Encrypt, CryptoKeyAlgorithm::AesGcm, ParamsKind::AesGcm },
        Registration { Operation::Decrypt, CryptoKeyAlgorithm::RsaEsPkcs1V15, ParamsKind::None },
        Registration { Operation::Decrypt, CryptoKeyAlgorithm::RsaOaep, ParamsKind::RsaOaep },
        Registration { Operation::Decrypt, CryptoKeyAlgorithm::AesCtr, ParamsKind::AesCtr },
        Registration { Operation::Decrypt, CryptoKeyAlgorithm::AesCbc, ParamsKind::AesCbc },
        Registration { Operation::Decrypt, CryptoKeyAlgorithm::AesCfb, ParamsKind::AesCbc },
        Registration { Operation::Decrypt, CryptoKeyAlgorithm::AesGcm, ParamsKind::AesGcm },
        Registration { Operation::Sign, CryptoKeyAlgorithm::Hmac, ParamsKind::None },
        Registration { Operation::Sign, CryptoKeyAlgorithm::RsaSsaPkcs1V15, ParamsKind::None },
        Registration { Operation::Sign, CryptoKeyAlgorithm::RsaPss, ParamsKind::RsaPss },
        Registration { Operation::Sign, CryptoKeyAlgorithm::Ecdsa, ParamsKind::Hash },
        Registration { Operation::Sign, CryptoKeyAlgorithm::Ed25519, ParamsKind::None },
        Registration { Operation::Verify, CryptoKeyAlgorithm::Hmac, ParamsKind::None },
        Registration { Operation::Verify, CryptoKeyAlgorithm::RsaSsaPkcs1V15, ParamsKind::None },
        Registration { Operation::Verify, CryptoKeyAlgorithm::RsaPss, ParamsKind::RsaPss },
        Registration { Operation::Verify, CryptoKeyAlgorithm::Ecdsa, ParamsKind::Hash },
        Registration { Operation::Verify, CryptoKeyAlgorithm::Ed25519, ParamsKind::None },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::Hmac, ParamsKind::Hmac },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::AesCtr, ParamsKind::AesLength },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::AesCbc, ParamsKind::AesLength },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::AesCfb, ParamsKind::AesLength },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::AesGcm, ParamsKind::AesLength },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::AesKw, ParamsKind::AesLength },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::RsaEsPkcs1V15, ParamsKind::RsaKeyGen },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::RsaSsaPkcs1V15, ParamsKind::RsaHashedKeyGen },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::RsaPss, ParamsKind::RsaHashedKeyGen },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::RsaOaep, ParamsKind::RsaHashedKeyGen },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::Ecdsa, ParamsKind::EcKey },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::Ecdh, ParamsKind::EcKey },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::Ed25519, ParamsKind::None },
        Registration { Operation::GenerateKey, CryptoKeyAlgorithm::X25519, ParamsKind::None },
        Registration { Operation::DeriveBits, CryptoKeyAlgorithm::Ecdh, ParamsKind::EcdhKeyDerive },
        Registration { Operation::DeriveBits, CryptoKeyAlgorithm::X25519, ParamsKind::EcdhKeyDerive },
        Registration { Operation::DeriveBits, CryptoKeyAlgorithm::Pbkdf2, ParamsKind::Pbkdf2 },
        Registration { Operation::DeriveBits, CryptoKeyAlgorithm::Hkdf, ParamsKind::Hkdf },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::Hmac, ParamsKind::Hmac },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::AesCtr, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::AesCbc, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::AesCfb, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::AesGcm, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::AesKw, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::RsaEsPkcs1V15, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::RsaSsaPkcs1V15, ParamsKind::Hash },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::RsaPss, ParamsKind::Hash },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::RsaOaep, ParamsKind::Hash },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::Ecdsa, ParamsKind::EcKey },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::Ecdh, ParamsKind::EcKey },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::Ed25519, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::X25519, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::Pbkdf2, ParamsKind::None },
        Registration { Operation::ImportKey, CryptoKeyAlgorithm::Hkdf, ParamsKind::None },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::Hmac, ParamsKind::Hmac },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::AesCtr, ParamsKind::AesLength },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::AesCbc, ParamsKind::AesLength },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::AesCfb, ParamsKind::AesLength },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::AesGcm, ParamsKind::AesLength },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::AesKw, ParamsKind::AesLength },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::Pbkdf2, ParamsKind::None },
        Registration { Operation::GetKeyLength, CryptoKeyAlgorithm::Hkdf, ParamsKind::None },
        Registration { Operation::WrapKey, CryptoKeyAlgorithm::RsaOaep, ParamsKind::RsaOaep },
        Registration { Operation::WrapKey, CryptoKeyAlgorithm::AesCtr, ParamsKind::AesCtr },
        Registration { Operation::WrapKey, CryptoKeyAlgorithm::AesCbc, ParamsKind::AesCbc },
        Registration { Operation::WrapKey, CryptoKeyAlgorithm::AesCfb, ParamsKind::AesCbc },
        Registration { Operation::WrapKey, CryptoKeyAlgorithm::AesGcm, ParamsKind::AesGcm },
        Registration { Operation::WrapKey, CryptoKeyAlgorithm::AesKw, ParamsKind::None },
        Registration { Operation::UnwrapKey, CryptoKeyAlgorithm::RsaOaep, ParamsKind::RsaOaep },
        Registration { Operation::UnwrapKey, CryptoKeyAlgorithm::AesCtr, ParamsKind::AesCtr },
        Registration { Operation::UnwrapKey, CryptoKeyAlgorithm::AesCbc, ParamsKind::AesCbc },
        Registration { Operation::UnwrapKey, CryptoKeyAlgorithm::AesCfb, ParamsKind::AesCbc },
        Registration { Operation::UnwrapKey, CryptoKeyAlgorithm::AesGcm, ParamsKind::AesGcm },
        Registration { Operation::UnwrapKey, CryptoKeyAlgorithm::AesKw, ParamsKind::None },
    };

    constexpr std::array allCurveSpecs {
        CurveSpec { CryptoKeyNamedCurve::None, ""_s, NID_undef, 0, nullptr },
        CurveSpec { CryptoKeyNamedCurve::P256, "P-256"_s, NID_X9_62_prime256v1, 32, EVP_pkey_ec_p256 },
        CurveSpec { CryptoKeyNamedCurve::P384, "P-384"_s, NID_secp384r1, 48, EVP_pkey_ec_p384 },
        CurveSpec { CryptoKeyNamedCurve::P521, "P-521"_s, NID_secp521r1, 66, EVP_pkey_ec_p521 },
        CurveSpec { CryptoKeyNamedCurve::Ed25519, "Ed25519"_s, NID_ED25519, 32, EVP_pkey_ed25519 },
        CurveSpec { CryptoKeyNamedCurve::X25519, "X25519"_s, NID_X25519, 32, EVP_pkey_x25519 },
    };

    constexpr std::array ecCurves { CryptoKeyNamedCurve::P256, CryptoKeyNamedCurve::P384, CryptoKeyNamedCurve::P521 };

    // Rows AES-CTR, AES-CBC, 8-bit AES-CFB, AES-GCM and AES-KW, which follow one another in CryptoKeyAlgorithm; columns
    // 128, 192 and 256 bits.
    constexpr std::array<std::array<WTF::ASCIILiteral, 3>, 5> aesJwkAlgorithms { {
        { "A128CTR"_s, "A192CTR"_s, "A256CTR"_s },
        { "A128CBC"_s, "A192CBC"_s, "A256CBC"_s },
        { "A128CFB8"_s, "A192CFB8"_s, "A256CFB8"_s },
        { "A128GCM"_s, "A192GCM"_s, "A256GCM"_s },
        { "A128KW"_s, "A192KW"_s, "A256KW"_s },
    } };

    // Rows RSASSA-PKCS1-v1_5, RSA-PSS and RSA-OAEP, which follow one another in CryptoKeyAlgorithm; columns the SHA-1
    // and SHA-2 hashes in WebCryptoHash order. JWK defines no RSA `alg` for the SHA-3 hashes.
    constexpr std::array<std::array<WTF::ASCIILiteral, 5>, 3> rsaJwkAlgorithms { {
        { "RS1"_s, "RS224"_s, "RS256"_s, "RS384"_s, "RS512"_s },
        { "PS1"_s, "PS224"_s, "PS256"_s, "PS384"_s, "PS512"_s },
        { "RSA-OAEP"_s, "RSA-OAEP-224"_s, "RSA-OAEP-256"_s, "RSA-OAEP-384"_s, "RSA-OAEP-512"_s },
    } };

    template <typename Table> constexpr bool followsEnumOrder(const Table& table)
    {
        for (size_t index = 0; index < table.size(); ++index) {
            if (static_cast<size_t>(table[index].id) != index)
                return false;
        }
        return true;
    }

    static_assert(followsEnumOrder(allAlgorithmSpecs));
    static_assert(allAlgorithmSpecs.size() == static_cast<size_t>(CryptoKeyAlgorithm::Hkdf) + 1);
    static_assert(followsEnumOrder(allCurveSpecs));
    static_assert(allCurveSpecs.size() == static_cast<size_t>(CryptoKeyNamedCurve::X25519) + 1);
    static_assert(static_cast<size_t>(CryptoKeyAlgorithm::AesKw) - static_cast<size_t>(CryptoKeyAlgorithm::AesCtr) + 1
        == aesJwkAlgorithms.size());
    static_assert(
        static_cast<size_t>(CryptoKeyAlgorithm::RsaOaep) - static_cast<size_t>(CryptoKeyAlgorithm::RsaSsaPkcs1V15) + 1
        == rsaJwkAlgorithms.size());
    static_assert(static_cast<size_t>(WebCryptoHash::SHA512) + 1 == 5);

    bool namesAlgorithm(const AlgorithmSpec& spec, const WTF::String& name)
    {
        if (WTF::equalIgnoringASCIICase(name, spec.name))
            return true;
        return !spec.alias.isEmpty() && WTF::equalIgnoringASCIICase(name, spec.alias);
    }

} // namespace

const AlgorithmSpec& algorithmSpec(CryptoKeyAlgorithm algorithm)
{
    return allAlgorithmSpecs[static_cast<size_t>(algorithm)];
}

uint8_t allowedUsages(const AlgorithmSpec& spec, CryptoKeyType type)
{
    switch (type) {
    case CryptoKeyType::Secret:
        return spec.secret_usages;
    case CryptoKeyType::Public:
        return spec.public_usages;
    case CryptoKeyType::Private:
        return spec.private_usages;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

const Registration* findRegistration(Operation operation, const WTF::String& name)
{
    for (const auto& registration : allRegistrations) {
        if (registration.operation == operation && namesAlgorithm(algorithmSpec(registration.algorithm), name))
            return &registration;
    }
    return nullptr;
}

const CurveSpec& curveSpec(CryptoKeyNamedCurve curve)
{
    ASSERT(curve != CryptoKeyNamedCurve::None);
    return allCurveSpecs[static_cast<size_t>(curve)];
}

std::optional<CryptoKeyNamedCurve> ecCurveFromName(const WTF::String& name)
{
    for (auto curve : ecCurves) {
        if (WTF::equalIgnoringASCIICase(name, curveSpec(curve).name))
            return curve;
    }
    return std::nullopt;
}

std::optional<CryptoKeyNamedCurve> ecCurveFromNid(int nid)
{
    for (auto curve : ecCurves) {
        if (curveSpec(curve).nid == nid)
            return curve;
    }
    return std::nullopt;
}

WTF::ASCIILiteral aesJwkAlgorithm(CryptoKeyAlgorithm algorithm, size_t key_bytes)
{
    const size_t row = static_cast<size_t>(algorithm) - static_cast<size_t>(CryptoKeyAlgorithm::AesCtr);
    RELEASE_ASSERT(row < aesJwkAlgorithms.size());
    switch (key_bytes) {
    case 16:
        return aesJwkAlgorithms[row][0];
    case 24:
        return aesJwkAlgorithms[row][1];
    case 32:
        return aesJwkAlgorithms[row][2];
    default:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

WTF::ASCIILiteral rsaJwkAlgorithm(CryptoKeyAlgorithm algorithm, WebCryptoHash hash)
{
    if (algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15)
        return "RSA1_5"_s;
    const size_t row = static_cast<size_t>(algorithm) - static_cast<size_t>(CryptoKeyAlgorithm::RsaSsaPkcs1V15);
    RELEASE_ASSERT(row < rsaJwkAlgorithms.size());
    const size_t column = static_cast<size_t>(hash);
    if (column >= rsaJwkAlgorithms[row].size())
        return ""_s;
    return rsaJwkAlgorithms[row][column];
}

}
