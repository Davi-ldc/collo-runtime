// Shared vocabulary of the WebCrypto bridge: the algorithm, hash, curve, key type, usage and key format enumerations,
// the hash table, the bounds Collo puts on keys and derived bytes, and `SecretBytes`, the container every secret byte
// lives in (secret_bytes.h). Nothing here touches JSC. Bounds that are worst-case times rather than sizes live in
// budget.h.

#pragma once

#include "host_functions/webapi/crypto/secret_bytes.h"

#include <openssl/digest.h>
#include <wtf/FastMalloc.h>
#include <wtf/Forward.h>
#include <wtf/text/ASCIILiteral.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace Collo::HostFunctions::WebCrypto {

// The modulus of any RSA key a CryptoKey holds, imported or generated, lies within these bounds; `createAsymmetricKey`
// refuses any other.
constexpr uint32_t rsa_modulus_bits_min = 1024;
constexpr uint32_t rsa_modulus_bits_max = 8192;
// The largest modulus generateKey creates. Key generation searches for random primes, so its time grows fast with the
// modulus and has a long tail: about a second at 4096 bits on the reference machine and tens of seconds at 8192. It
// checks the clock as it goes (budget.h); this bound is the outer limit, so no call holds the VM thread for tens of
// seconds even when the time left would allow it.
constexpr uint32_t rsa_generate_modulus_bits_max = 4096;
// The largest output of one key derivation.
constexpr size_t derived_bytes_max = 1024 * 1024;
// The largest input BoringSSL processes in one call nothing can interrupt: an Ed25519 message, an RSA-OAEP label, an
// AES-GCM IV that is not 12 bytes long, and the data of AES key wrap. On the reference machine the slowest of them at
// this size, key wrap, takes about 24 ms, below a private-key operation of an 8192-bit RSA key (budget.cpp).
constexpr size_t single_call_input_bytes_max = 1024 * 1024;
// The largest JWK text unwrapKey parses. It holds every key Collo exports, the largest an RSA private key of
// `rsa_modulus_bits_max` bits or an HMAC key of `generated_secret_bytes_max` bytes, well under 128 KiB, and keeps the
// text far from the engine's string length limit.
constexpr size_t jwk_text_bytes_max = 1024 * 1024;
// The largest HMAC key generateKey or deriveKey creates.
constexpr size_t generated_secret_bytes_max = 64 * 1024;
// The most entries a key usages list or a JWK `key_ops` list may have. Eight usages exist; the bound refuses a list
// long enough to cost the VM thread a measurable time to read.
constexpr uint64_t key_usages_length_max = 64;

enum class WebCryptoHash : uint8_t {
    SHA1,
    SHA224,
    SHA256,
    SHA384,
    SHA512,
    SHA3_224,
    SHA3_256,
    SHA3_384,
    SHA3_512,
};

// The order is the `algorithmSpec` table's (algorithms.cpp), which indexes by this value.
enum class CryptoKeyAlgorithm : uint8_t {
    Hmac,
    AesCtr,
    AesCbc,
    AesCfb,
    AesGcm,
    AesKw,
    RsaEsPkcs1V15,
    RsaSsaPkcs1V15,
    RsaPss,
    RsaOaep,
    Ecdsa,
    Ecdh,
    Ed25519,
    X25519,
    Pbkdf2,
    Hkdf,
};

enum class CryptoKeyType : uint8_t {
    Secret,
    Public,
    Private,
};

enum class CryptoKeyNamedCurve : uint8_t {
    None,
    P256,
    P384,
    P521,
    Ed25519,
    X25519,
};

// Usage bits of a CryptoKey. The bit values are internal; the order in which usages appear to JavaScript is
// `orderedCryptoKeyUsages` in normalize.h.
enum CryptoKeyUsage : uint8_t {
    CryptoKeyUsageEncrypt = 1 << 0,
    CryptoKeyUsageDecrypt = 1 << 1,
    CryptoKeyUsageSign = 1 << 2,
    CryptoKeyUsageVerify = 1 << 3,
    CryptoKeyUsageWrapKey = 1 << 4,
    CryptoKeyUsageUnwrapKey = 1 << 5,
    CryptoKeyUsageDeriveBits = 1 << 6,
    CryptoKeyUsageDeriveKey = 1 << 7,
};

// The KeyFormat enumeration of the Web Cryptography API.
enum class KeyFormat : uint8_t {
    Raw,
    Spki,
    Pkcs8,
    Jwk,
};

// One entry of the static hash table. References to entries stay valid for the life of the process.
struct HashSpec {
    WebCryptoHash id;
    WTF::ASCIILiteral name;
    // BoringSSL's digest; every entry has one, the SHA-3 hashes through the patch series in
    // `runtime/patches/boringssl/`.
    const EVP_MD* (*evp)();
    size_t digest_bytes;
    // The hash's block size in bits: the HMAC key length when an HMAC algorithm gives no `length`.
    size_t block_bits;
    // The JWK `alg` of an HMAC key with this hash; empty for the SHA-3 hashes, which have none.
    WTF::ASCIILiteral jwk_alg;
};

// The allocator of the bridge's `SecretBytes`: fastMalloc, which every other buffer of the bridge uses too.
struct FastMallocSecretAllocator {
    static uint8_t* tryAllocate(size_t size)
    {
        void* data = nullptr;
        if (!WTF::tryFastMalloc(size).getValue(data))
            return nullptr;
        return static_cast<uint8_t*>(data);
    }

    static void deallocate(uint8_t* data, size_t) { WTF::fastFree(data); }
};

using SecretBytes = BasicSecretBytes<FastMallocSecretAllocator>;

// Empties `out`, zeroing its buffer, and returns false: how a primitive that fills a SecretBytes fails, so its output
// is empty on every failure.
inline bool clearAndFail(SecretBytes& out)
{
    out.clear();
    return false;
}

// The value of `number` as a T when it is a finite integer within [min, max]; no value otherwise.
template <typename T> std::optional<T> integerInRange(double number, T min, T max)
{
    if (!std::isfinite(number) || std::floor(number) != number)
        return std::nullopt;
    if (number < static_cast<double>(min) || number > static_cast<double>(max))
        return std::nullopt;
    return static_cast<T>(number);
}

const HashSpec& hashSpec(WebCryptoHash);
// Matches the name without regard to ASCII case; null for a hash the table does not have.
const HashSpec* hashSpecFromName(const WTF::String&);

}
