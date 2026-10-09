// Shared vocabulary of the WebCrypto bridge: the algorithm, hash, curve, key type and usage enumerations, the hash
// table, the bounds Collo puts on WebCrypto inputs, and containers that zero secret bytes. Nothing here touches JSC,
// so crypto pool threads use these types as freely as the VM thread.

#pragma once

#include <openssl/digest.h>
#include <wtf/Forward.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>

#include <cstddef>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

// Largest PBKDF2 iteration count; a larger count, or zero, rejects with OperationError.
constexpr uint32_t maxWebCryptoPbkdf2Iterations = 1'000'000;
// Bounds on an RSA modulus. generateKey rejects a length outside them with OperationError, and `createRsaKey`
// refuses any key outside them.
constexpr uint32_t minWebCryptoRsaModulusLengthBits = 1024;
constexpr uint32_t maxWebCryptoRsaModulusLengthBits = 8192;
// Largest output of one key derivation, in bytes.
constexpr size_t maxWebCryptoDerivedBytes = 1024 * 1024;
// Largest HMAC key that generateKey or deriveKey creates, in bytes.
constexpr size_t maxWebCryptoGeneratedSecretBytes = 64 * 1024;
// A digest of at most this many input bytes runs inline on the VM thread instead of on the crypto pool.
constexpr size_t inlineDigestByteLimit = 64;

// Where `enqueueCryptoJobPromise` runs a job: inline on the VM thread, or on the crypto pool.
enum class CryptoJobCost : uint8_t {
    InlinePreferred,
    Heavy,
};

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
// `orderedCryptoKeyUsages` in `normalize.h`.
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

// One entry of the static hash table. Pointers to entries stay valid for the life of the process.
struct HashSpec {
    WebCryptoHash id;
    WTF::ASCIILiteral name;
    const EVP_MD* (*evp)();
    size_t digest_bytes;
    // The hash's block size in bits: the HMAC key length when an HMAC algorithm gives no `length`.
    size_t default_hmac_bits;
    // The JWK `alg` of an HMAC key with this hash; empty for the SHA-3 hashes, which have none.
    WTF::ASCIILiteral jwk_alg;
};

// Owns bytes that may be secret and zeroes them on destruction, on `clear`, and before a move assignment overwrites
// them. `release` hands the vector to a new owner without zeroing it, and that owner takes over the duty.
class SecureBytes {
public:
    SecureBytes() = default;
    explicit SecureBytes(WTF::Vector<uint8_t>&&);
    SecureBytes(SecureBytes&&);
    SecureBytes& operator=(SecureBytes&&);
    SecureBytes(const SecureBytes&) = delete;
    SecureBytes& operator=(const SecureBytes&) = delete;
    ~SecureBytes();

    bool tryAppend(std::span<const uint8_t>);
    std::span<const uint8_t> span() const;
    bool isEmpty() const;
    WTF::Vector<uint8_t>& vector();
    WTF::Vector<uint8_t>&& release();
    void clear();

private:
    WTF::Vector<uint8_t> m_bytes;
};

// Zeroes a vector it does not own when the guard goes out of scope. Call `dismiss` once the bytes have moved to an
// owner that zeroes them itself. The vector must outlive the guard.
class SecureVectorGuard {
public:
    explicit SecureVectorGuard(WTF::Vector<uint8_t>&);
    SecureVectorGuard(SecureVectorGuard&&);
    SecureVectorGuard& operator=(SecureVectorGuard&&);
    SecureVectorGuard(const SecureVectorGuard&) = delete;
    SecureVectorGuard& operator=(const SecureVectorGuard&) = delete;
    ~SecureVectorGuard();

    void dismiss();

private:
    WTF::Vector<uint8_t>* m_vector { nullptr };
};

void secureZeroVector(WTF::Vector<uint8_t>&);
// True when `number` is a finite integer within [min, max]. The typed variants store the value in `out` only then.
bool checkedIntegerInRange(double, double min, double max);
bool checkedSizeFromNumber(double, size_t min, size_t max, size_t& out);
bool checkedUInt32FromNumber(double, uint32_t min, uint32_t max, uint32_t& out);
bool checkedUInt8FromNumber(double, uint8_t min, uint8_t max, uint8_t& out);

const HashSpec& hashSpec(WebCryptoHash);
// Matches the name without regard to ASCII case; null for a hash the table does not have.
const HashSpec* hashSpecFromName(const WTF::String&);
// Null when BoringSSL has no EVP digest for the hash. Every table entry has one, since the BoringSSL patch series in
// `runtime/patches/boringssl/` exposes the SHA-3 digests.
const EVP_MD* hashEvp(const HashSpec&);
bool hashHasOpenSslEvp(const HashSpec&);

}
