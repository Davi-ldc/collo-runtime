// CryptoKey creation and the key checks of the SubtleCrypto methods, on the VM thread, plus the BIGNUM conversions key
// import and export share. The factories read the CryptoKey structure the global object caches and downcast without a
// check, so the global object must be a `Collo::GlobalObject` whose Web APIs are installed.

#pragma once

#include "host_functions/webapi/crypto/algorithms.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/types.h"

#include <openssl/bn.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <wtf/Vector.h>

#include <span>

namespace JSC {
class JSGlobalObject;
class ThrowScope;
}

namespace Collo::HostFunctions::WebCrypto {

// An HMAC, AES, PBKDF2 or HKDF key taking `material`. `hmac_length_bits` is the `length` an HMAC import declared, or 0.
JSColloCryptoKey* createSecretKey(JSC::JSGlobalObject*, CryptoKeyAlgorithm, WebCryptoHash, SecretBytes&& material,
    bool extractable, uint8_t usages, size_t hmac_length_bits = 0);

struct AsymmetricKeyAttributes {
    CryptoKeyAlgorithm algorithm { CryptoKeyAlgorithm::RsaPss };
    // The hash of an RSA algorithm that takes one; RSAES-PKCS1-v1_5 keys keep SHA-1, which nothing reads.
    WebCryptoHash hash { WebCryptoHash::SHA1 };
    // The curve an ECDSA or ECDH key must be on; ignored for the other families.
    CryptoKeyNamedCurve named_curve { CryptoKeyNamedCurve::None };
    CryptoKeyType type { CryptoKeyType::Public };
    bool extractable { false };
    uint8_t usages { 0 };
};

// Takes `pkey` into a new CryptoKey when it fits the attributes: an RSA key whose modulus lies within
// [rsa_modulus_bits_min, rsa_modulus_bits_max], an EC key on the named curve, or a key of the type an Ed25519 or X25519
// algorithm names. Returns null otherwise, leaving `pkey` with the caller.
JSColloCryptoKey* createAsymmetricKey(JSC::JSGlobalObject*, const AsymmetricKeyAttributes&, bssl::UniquePtr<EVP_PKEY>&);

// The usage rule for a key an operation creates, by import, generation or derivation, a SyntaxError on failure:
// `usages` holds only usages a `type` key of the algorithm may hold, and a secret or private key gets at least one.
void checkNewKeyUsages(JSC::JSGlobalObject*, JSC::ThrowScope&, const AlgorithmSpec&, CryptoKeyType, uint8_t usages);

// The key type an operation that needs `usage` uses with an algorithm: secret for a secret-key algorithm; otherwise
// public to encrypt, verify and wrap, and private for the rest.
CryptoKeyType keyTypeFor(const AlgorithmSpec&, CryptoKeyUsage);

// The checks every SubtleCrypto method makes of the key it operates with, each an InvalidAccessError: the key's
// algorithm is `algorithm`, its type is the one `keyTypeFor` names, and its usages hold `usage`.
void checkKey(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloCryptoKey*, CryptoKeyAlgorithm, CryptoKeyUsage);

// Writes the big-endian magnitude of `bn` to `out`, which must be empty; false for a null `bn` or a failed allocation.
// The SecretBytes form is for a private component.
bool bnToBytes(const BIGNUM*, WTF::Vector<uint8_t>& out);
bool bnToBytes(const BIGNUM*, SecretBytes& out);
// Reads a big-endian magnitude; null for empty input or a failed allocation.
bssl::UniquePtr<BIGNUM> bytesToBn(std::span<const uint8_t>);
// Each wraps the key in a new `EVP_PKEY` that takes its own reference, so the caller keeps its own.
bssl::UniquePtr<EVP_PKEY> pkeyFromRsa(RSA*);
bssl::UniquePtr<EVP_PKEY> pkeyFromEc(EC_KEY*);

}
