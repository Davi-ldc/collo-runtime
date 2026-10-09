// Symmetric primitives behind Web Crypto: HMAC, AES in the GCM, CBC, 8-bit CFB, CTR and KW modes, and message
// digests, over BoringSSL and the SHA-3 in sha3.cpp. They take and return native bytes and touch no JavaScript value,
// so they run on whichever thread runs the crypto job: a crypto pool thread, or the VM thread for a job run inline.
// Keys, parameters and inputs are borrowed for the call. An output vector must be empty, with no buffer, on entry; on
// failure it comes back empty, and bytes already written to it are zeroed first.

#pragma once

#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/types.h"

#include <openssl/digest.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>

#include <array>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

// Writes the MAC to the first `out_len` bytes of `out`. Fails when the hash has no implementation or BoringSSL fails.
bool hmacSign(const HashSpec&, std::span<const uint8_t> key, std::span<const uint8_t> data,
    std::array<uint8_t, EVP_MAX_MD_SIZE>& out, unsigned& out_len);

bool isValidAesKeyLength(size_t byte_length);
// The JWK "alg" value of an AES key. The algorithm must be an AES variant and the length one isValidAesKeyLength
// accepts; any other pair reaches RELEASE_ASSERT_NOT_REACHED and ends the worker.
WTF::ASCIILiteral aesJwkAlgorithm(CryptoKeyAlgorithm, size_t byte_length);

// Encryption appends the authentication tag of `tag_bytes` to the ciphertext, and decryption expects it at the end of
// its input. A tag that does not verify fails the decryption and zeroes the plaintext written so far.
bool aesGcmEncrypt(
    std::span<const uint8_t> key, const AesGcmParams&, std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out);
bool aesGcmDecrypt(std::span<const uint8_t> key, const AesGcmParams&, std::span<const uint8_t> ciphertext_and_tag,
    WTF::Vector<uint8_t>& out);
bool aesCbcEncrypt(
    std::span<const uint8_t> key, const AesCbcParams&, std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out);
bool aesCbcDecrypt(
    std::span<const uint8_t> key, const AesCbcParams&, std::span<const uint8_t> ciphertext, WTF::Vector<uint8_t>& out);
bool aesCfb8Encrypt(
    std::span<const uint8_t> key, const AesCfbParams&, std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out);
bool aesCfb8Decrypt(
    std::span<const uint8_t> key, const AesCfbParams&, std::span<const uint8_t> ciphertext, WTF::Vector<uint8_t>& out);
// Encrypts and decrypts alike. The rightmost `length` bits of the counter block count up and the rest stay fixed, so
// an input that needs more than 2^length blocks fails instead of reusing a counter value.
bool aesCtrTransform(
    std::span<const uint8_t> key, const AesCtrParams&, std::span<const uint8_t> input, WTF::Vector<uint8_t>& out);
// RFC 3394 key wrap with the default IV. The plaintext must be a multiple of 8 bytes and at least 16, so a ciphertext
// is at least 24, and unwrapping fails when the integrity check does not match.
bool aesKwWrap(std::span<const uint8_t> key, std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out);
bool aesKwUnwrap(std::span<const uint8_t> key, std::span<const uint8_t> ciphertext, WTF::Vector<uint8_t>& out);
bool digestBytes(const HashSpec&, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out);

}
