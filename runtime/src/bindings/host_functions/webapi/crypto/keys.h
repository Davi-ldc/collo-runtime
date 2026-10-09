// Per key family (AES, HMAC, PBKDF2 and HKDF, RSA, EC, OKP): algorithm and curve names, the usages each key type may
// hold, conversions between BoringSSL objects and bytes, and the factories that turn validated material into a
// `JSColloCryptoKey`. The `create*Key` factories allocate a cell and run only on the VM thread, with a
// `Collo::GlobalObject` as the global object. Every other function touches no JSC state, and generateKey jobs call
// several of them on a crypto pool thread.

#pragma once

#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/types.h"

#include <openssl/bn.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <memory>
#include <optional>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

// Takes a new reference on `key` for a crypto job, so the job can keep using the key after the CryptoKey cell that
// owns it is swept. The job drops the reference when it is destroyed, on the VM thread, and pool threads only read the
// key (see `m_rsa_key` in objects.h). Returns null for a null key or a failed up-ref.
std::shared_ptr<EVP_PKEY> retainSharedPkey(EVP_PKEY*);

bool isAesAlgorithm(CryptoKeyAlgorithm);
WTF::ASCIILiteral aesAlgorithmName(CryptoKeyAlgorithm);
std::optional<CryptoKeyAlgorithm> aesAlgorithmFromName(const WTF::String&);
uint8_t allowedUsagesForAes(CryptoKeyAlgorithm);
// Takes the bytes and never returns null, like `createHmacKey` and `createRawDeriveKey`.
JSColloCryptoKey* createAesKey(
    JSC::JSGlobalObject*, CryptoKeyAlgorithm, WTF::Vector<uint8_t>&& material, bool extractable, uint8_t usages);

// `declared_length_bits` is the `length` an import declared, or 0 when it declared none; `key.algorithm.length`
// reports it (`JSColloCryptoKey::hmacLengthBits`).
JSColloCryptoKey* createHmacKey(JSC::JSGlobalObject*, WebCryptoHash, WTF::Vector<uint8_t>&& material, bool extractable,
    uint8_t usages, size_t declared_length_bits = 0);

// A PBKDF2 or HKDF key, which is never extractable.
JSColloCryptoKey* createRawDeriveKey(
    JSC::JSGlobalObject*, CryptoKeyAlgorithm, WTF::Vector<uint8_t>&& material, uint8_t usages);

bool isRsaAlgorithm(CryptoKeyAlgorithm);
WTF::ASCIILiteral rsaAlgorithmName(CryptoKeyAlgorithm);
std::optional<CryptoKeyAlgorithm> rsaAlgorithmFromName(const WTF::String&);
uint8_t allowedPublicUsagesForRsa(CryptoKeyAlgorithm);
uint8_t allowedPrivateUsagesForRsa(CryptoKeyAlgorithm);
uint8_t allowedUsagesForRsa(CryptoKeyAlgorithm);
// Empty when JWK defines no `alg` for the pair, as for the SHA-3 hashes.
WTF::ASCIILiteral rsaJwkAlgorithm(CryptoKeyAlgorithm, WebCryptoHash);
// Writes the big-endian magnitude of `bn` to `out`; false for a null `bn` or a failed allocation.
bool bnToBytes(const BIGNUM*, WTF::Vector<uint8_t>& out);
// Reads a big-endian magnitude; null for empty input or a failed allocation.
bssl::UniquePtr<BIGNUM> bytesToBn(std::span<const uint8_t>);
// Wraps `rsa` in a new `EVP_PKEY` that takes its own reference, so the caller keeps its own; `pkeyFromEc` does the
// same for an `EC_KEY`.
bssl::UniquePtr<EVP_PKEY> pkeyFromRsa(RSA*);
// The asymmetric factories return null, without throwing, for a key that does not fit: an RSA modulus outside the
// WebCrypto bounds, an EC key on another curve, or a key of another type. Then the caller's pointer still owns the
// key; otherwise the new cell does.
JSColloCryptoKey* createRsaKey(JSC::JSGlobalObject*, CryptoKeyAlgorithm, WebCryptoHash, CryptoKeyType,
    bssl::UniquePtr<EVP_PKEY>&&, bool extractable, uint8_t usages);

bool isEcAlgorithm(CryptoKeyAlgorithm);
WTF::ASCIILiteral ecAlgorithmName(CryptoKeyAlgorithm);
std::optional<CryptoKeyAlgorithm> ecAlgorithmFromName(const WTF::String&);
WTF::ASCIILiteral namedCurveName(CryptoKeyNamedCurve);
// The curve lookups and sizes cover only the EC curves P-256, P-384 and P-521; for the OKP curves they return no
// value, `NID_undef` or 0.
std::optional<CryptoKeyNamedCurve> namedCurveFromName(const WTF::String&);
int nidForNamedCurve(CryptoKeyNamedCurve);
std::optional<CryptoKeyNamedCurve> namedCurveFromNid(int);
size_t coordinateBytesForNamedCurve(CryptoKeyNamedCurve);
uint8_t allowedPublicUsagesForEc(CryptoKeyAlgorithm);
uint8_t allowedPrivateUsagesForEc(CryptoKeyAlgorithm);
uint8_t allowedUsagesForEc(CryptoKeyAlgorithm);
bssl::UniquePtr<EVP_PKEY> pkeyFromEc(EC_KEY*);
JSColloCryptoKey* createEcKey(JSC::JSGlobalObject*, CryptoKeyAlgorithm, CryptoKeyType, CryptoKeyNamedCurve,
    bssl::UniquePtr<EVP_PKEY>&&, bool extractable, uint8_t usages);

bool isOkpAlgorithm(CryptoKeyAlgorithm);
WTF::ASCIILiteral okpAlgorithmName(CryptoKeyAlgorithm);
std::optional<CryptoKeyAlgorithm> okpAlgorithmFromName(const WTF::String&);
CryptoKeyNamedCurve okpCurveForAlgorithm(CryptoKeyAlgorithm);
int evpTypeForOkp(CryptoKeyAlgorithm);
uint8_t allowedPublicUsagesForOkp(CryptoKeyAlgorithm);
uint8_t allowedPrivateUsagesForOkp(CryptoKeyAlgorithm);
uint8_t allowedUsagesForOkp(CryptoKeyAlgorithm);
JSColloCryptoKey* createOkpKey(JSC::JSGlobalObject*, CryptoKeyAlgorithm, CryptoKeyType, bssl::UniquePtr<EVP_PKEY>&&,
    bool extractable, uint8_t usages);

}
