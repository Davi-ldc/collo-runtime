// The Web Cryptography API's algorithm registry as constant tables: one `AlgorithmSpec` per algorithm (its names, key
// family, the usages each key type may hold and the JWK `use` its usages match), the registration of each algorithm
// for each operation with the parameter dictionary that operation reads, the named curves, and the JWK `alg` values.
// Normalization (normalize.h), key creation (keys.h) and import and export (key_io/) read these tables instead of
// deciding per algorithm. Everything is constant data the zygote maps read-only, and nothing here touches JSC.

#pragma once

#include "host_functions/webapi/crypto/types.h"

#include <openssl/evp.h>
#include <wtf/Forward.h>
#include <wtf/text/ASCIILiteral.h>

#include <cstddef>
#include <cstdint>
#include <optional>

namespace Collo::HostFunctions::WebCrypto {

enum class AlgorithmFamily : uint8_t {
    Hmac,
    Aes,
    Kdf,
    Rsa,
    Ec,
    Okp,
};

struct AlgorithmSpec {
    CryptoKeyAlgorithm id;
    // The name `key.algorithm.name` reports.
    WTF::ASCIILiteral name;
    // A second name normalization accepts, or empty.
    WTF::ASCIILiteral alias;
    AlgorithmFamily family;
    // The usages a key of each type may hold. An HMAC, AES, PBKDF2 or HKDF key is secret; the others come in pairs.
    uint8_t secret_usages;
    uint8_t public_usages;
    uint8_t private_usages;
    // The curve of an Ed25519 or X25519 key, which the algorithm fixes; None for every other algorithm.
    CryptoKeyNamedCurve okp_curve;
    // The JWK `use` a key with usages must declare if it declares one; empty for PBKDF2 and HKDF, which have no JWK
    // form.
    WTF::ASCIILiteral jwk_use;
};

const AlgorithmSpec& algorithmSpec(CryptoKeyAlgorithm);
uint8_t allowedUsages(const AlgorithmSpec&, CryptoKeyType);

// The operations that normalize an algorithm. `GetKeyLength` reads deriveKey's derivedKeyType once for both the "get
// key length" and the "import key" steps, since the parameters of the second are a subset of the first's.
enum class Operation : uint8_t {
    Encrypt,
    Decrypt,
    Sign,
    Verify,
    GenerateKey,
    DeriveBits,
    ImportKey,
    GetKeyLength,
    WrapKey,
    UnwrapKey,
};

// The parameter dictionary an operation reads for an algorithm, beyond `name`.
enum class ParamsKind : uint8_t {
    // A plain Algorithm dictionary.
    None,
    // AesCbcParams, which 8-bit AES-CFB shares.
    AesCbc,
    AesCtr,
    AesGcm,
    // AesKeyGenParams and AesDerivedKeyParams: a `length`.
    AesLength,
    // HmacImportParams and HmacKeyGenParams: a `hash` and an optional `length`.
    Hmac,
    // RsaHashedImportParams and EcdsaParams: a `hash`.
    Hash,
    RsaKeyGen,
    RsaHashedKeyGen,
    RsaPss,
    RsaOaep,
    // EcKeyGenParams and EcKeyImportParams: a `namedCurve`.
    EcKey,
    // EcdhKeyDeriveParams, which X25519 shares: a `public` CryptoKey.
    EcdhKeyDerive,
    Pbkdf2,
    Hkdf,
};

struct Registration {
    Operation operation;
    CryptoKeyAlgorithm algorithm;
    ParamsKind params;
};

// The registration of the algorithm `name` names for `operation`, matched without regard to ASCII case against its
// name and alias; null when `operation` registers no such algorithm.
const Registration* findRegistration(Operation, const WTF::String& name);

struct CurveSpec {
    CryptoKeyNamedCurve id;
    WTF::ASCIILiteral name;
    int nid;
    // The byte length of a coordinate or private scalar of an EC key, or of a raw Ed25519 or X25519 key.
    size_t coordinate_bytes;
    // The one key type a SubjectPublicKeyInfo or PrivateKeyInfo may hold for this curve.
    const EVP_PKEY_ALG* (*pkey_alg)();
};

// Defined for every curve but None.
const CurveSpec& curveSpec(CryptoKeyNamedCurve);
// The EC curves P-256, P-384 and P-521 only; no value for any other name or nid.
std::optional<CryptoKeyNamedCurve> ecCurveFromName(const WTF::String&);
std::optional<CryptoKeyNamedCurve> ecCurveFromNid(int);

// The JWK `alg` of an AES key of `key_bytes` bytes, which must be 16, 24 or 32.
WTF::ASCIILiteral aesJwkAlgorithm(CryptoKeyAlgorithm, size_t key_bytes);
// The JWK `alg` of an RSA key; empty when JWK defines none for the pair, as for the SHA-3 hashes.
WTF::ASCIILiteral rsaJwkAlgorithm(CryptoKeyAlgorithm, WebCryptoHash);

}
