// Symmetric primitives behind Web Crypto: message digests, HMAC, and AES in the GCM, CBC, 8-bit CFB, CTR and KW modes,
// over BoringSSL. They take native bytes and touch no JavaScript value; the SubtleCrypto methods call them on the VM
// thread. Keys, parameters and inputs are borrowed for the call, so no script may run while one executes. An output
// `SecretBytes` must be empty on entry and comes back empty on failure, its buffer zeroed and freed.
//
// Every primitive but key wrap works through its input in slices and spends each slice's estimate on the caller's
// `TimeGuard` (budget.h) first, so a long input stops, as a failure, once the guard refuses. Key wrap runs in one
// BoringSSL call, so its caller bounds the input and asks the guard before it.

#pragma once

#include "host_functions/webapi/crypto/budget.h"
#include "host_functions/webapi/crypto/types.h"

#include <openssl/digest.h>
#include <openssl/hmac.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

// Writes the digest's `digest_bytes` to the front of `out`.
bool digestBytes(const HashSpec&, std::span<const uint8_t> data, std::array<uint8_t, EVP_MAX_MD_SIZE>& out, TimeGuard&);
// Writes the MAC's `digest_bytes` to the front of `out`.
bool hmacSign(const HashSpec&, std::span<const uint8_t> key, std::span<const uint8_t> data,
    std::array<uint8_t, EVP_MAX_MD_SIZE>& out, TimeGuard&);
// Keys a new `ctx` with `key` as HMAC_Init_ex does, after hashing a key longer than the hash's block in slices, which
// RFC 2104 makes the same key: HMAC_Init_ex would hash it in one call. PBKDF2 and HKDF build on these two.
bool hmacInit(HMAC_CTX*, const HashSpec&, std::span<const uint8_t> key, TimeGuard&);
bool hmacUpdate(HMAC_CTX*, const HashSpec&, std::span<const uint8_t> data, TimeGuard&);

bool isValidAesKeyLength(size_t byte_length);

// Encryption appends the authentication tag of `tag_bytes` to the ciphertext, and decryption expects it at the end of
// its input. A tag that does not verify fails the decryption and zeroes the plaintext written so far. An IV that is not
// 12 bytes long is hashed in one call, so the caller bounds it.
bool aesGcmEncrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> additional_data,
    size_t tag_bytes, std::span<const uint8_t> plaintext, SecretBytes& out, TimeGuard&);
bool aesGcmDecrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> additional_data,
    size_t tag_bytes, std::span<const uint8_t> ciphertext_and_tag, SecretBytes& out, TimeGuard&);
// `iv` is 16 bytes. CBC pads with PKCS#7.
bool aesCbcEncrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> plaintext,
    SecretBytes& out, TimeGuard&);
bool aesCbcDecrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> ciphertext,
    SecretBytes& out, TimeGuard&);
bool aesCfb8Encrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> plaintext,
    SecretBytes& out, TimeGuard&);
bool aesCfb8Decrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> ciphertext,
    SecretBytes& out, TimeGuard&);
// Encrypts and decrypts alike. The rightmost `counter_bits` bits of the 16-byte counter block count up and the rest
// stay fixed, so an input that needs more than 2^counter_bits blocks fails instead of reusing a counter value.
bool aesCtrTransform(std::span<const uint8_t> key, std::span<const uint8_t> counter, uint8_t counter_bits,
    std::span<const uint8_t> input, SecretBytes& out, TimeGuard&);
// RFC 3394 key wrap with the default IV, in one call. The plaintext must be a multiple of 8 bytes and at least 16, so a
// ciphertext is at least 24, and unwrapping fails when the integrity check does not match.
bool aesKwWrap(std::span<const uint8_t> key, std::span<const uint8_t> plaintext, SecretBytes& out);
bool aesKwUnwrap(std::span<const uint8_t> key, std::span<const uint8_t> ciphertext, SecretBytes& out);

}
