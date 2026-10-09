// Public-key primitives behind Web Crypto: RSA signatures and encryption, ECDSA, Ed25519, and ECDH and X25519 key
// agreement, over BoringSSL. They take native data and touch no JavaScript value, so they run on whichever thread runs
// the crypto job: a crypto pool thread, or the VM thread for a job run inline. Each EVP_PKEY is borrowed; the job holds
// its own reference (retainSharedPkey in keys.h), so the key outlives the call even after its CryptoKey is collected.
// An output vector must be empty, with no buffer, on entry, and comes back empty on failure. A verify function that
// rejects the signature sets `out` to false and still returns true; false means the check could not run.

#pragma once

#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/types.h"

#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <wtf/Vector.h>

#include <cstdint>
#include <optional>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

bool rsaSignDigestNative(EVP_PKEY*, WebCryptoHash, std::span<const uint8_t> data, int padding,
    std::optional<uint32_t> salt_length, WTF::Vector<uint8_t>& out);
bool rsaVerifyDigestNative(EVP_PKEY*, WebCryptoHash, std::span<const uint8_t> signature, std::span<const uint8_t> data,
    int padding, std::optional<uint32_t> salt_length, bool& out);
bool rsaOaepEncryptNative(EVP_PKEY*, WebCryptoHash, std::span<const uint8_t> label, std::span<const uint8_t> plaintext,
    WTF::Vector<uint8_t>& out);
bool rsaOaepDecryptNative(EVP_PKEY*, WebCryptoHash, std::span<const uint8_t> label, std::span<const uint8_t> ciphertext,
    WTF::Vector<uint8_t>& out);
bool rsaPkcs1EncryptNative(EVP_PKEY*, std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out);
bool rsaPkcs1DecryptNative(EVP_PKEY*, std::span<const uint8_t> ciphertext, WTF::Vector<uint8_t>& out);
bool ecdsaSignNative(EVP_PKEY*, WebCryptoHash, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out);
bool ecdsaVerifyNative(
    EVP_PKEY*, WebCryptoHash, std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out);
bool ed25519SignNative(EVP_PKEY*, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out);
bool ed25519VerifyNative(EVP_PKEY*, std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out);
// Each appends the first ceil(length_bits / 8) bytes of the shared secret to `out`, leaving the unused low bits of a
// partial last byte as derived. A zero length, or one longer than the secret, fails.
bool ecdhDeriveBitsNative(EVP_PKEY* private_key, EVP_PKEY* public_key, size_t length_bits, WTF::Vector<uint8_t>& out);
bool x25519DeriveBitsNative(EVP_PKEY* private_key, EVP_PKEY* public_key, size_t length_bits, WTF::Vector<uint8_t>& out);

}
