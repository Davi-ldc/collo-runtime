// Public-key primitives behind Web Crypto: RSA signatures and encryption, ECDSA, Ed25519, and ECDH and X25519 key
// agreement, over BoringSSL. They take native data and touch no JavaScript value; the SubtleCrypto methods call them on
// the VM thread. Each EVP_PKEY and input is borrowed for the call. An output `SecretBytes` must be empty on entry and
// comes back empty on failure. A verify function that rejects the signature sets `out` to false and still returns
// true; false means the check could not run.
//
// Each runs in BoringSSL calls nothing can interrupt, so its caller asks the operation's `TimeGuard` (budget.h) before
// it. RSA and ECDSA sign a digest the caller computed through the guard (`digestBytes` in symmetric.h), which keeps
// the message's length out of the uninterruptible part; the caller bounds an Ed25519 message and an RSA-OAEP label,
// which BoringSSL hashes in one call.

#pragma once

#include "host_functions/webapi/crypto/types.h"

#include <openssl/evp.h>

#include <cstddef>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

// RSA signatures over a `digest` of `hash`, with `padding` RSA_PKCS1_PADDING or RSA_PKCS1_PSS_PADDING, whose salt is
// `salt_length` bytes and whose mask generation function hashes with `hash` too.
bool rsaSignDigest(
    EVP_PKEY*, const HashSpec&, std::span<const uint8_t> digest, int padding, uint32_t salt_length, SecretBytes& out);
bool rsaVerifyDigest(EVP_PKEY*, const HashSpec&, std::span<const uint8_t> signature, std::span<const uint8_t> digest,
    int padding, uint32_t salt_length, bool& out);
bool rsaOaepEncrypt(
    EVP_PKEY*, const HashSpec&, std::span<const uint8_t> label, std::span<const uint8_t> plaintext, SecretBytes& out);
bool rsaOaepDecrypt(
    EVP_PKEY*, const HashSpec&, std::span<const uint8_t> label, std::span<const uint8_t> ciphertext, SecretBytes& out);
bool rsaPkcs1Encrypt(EVP_PKEY*, std::span<const uint8_t> plaintext, SecretBytes& out);
bool rsaPkcs1Decrypt(EVP_PKEY*, std::span<const uint8_t> ciphertext, SecretBytes& out);
// A Web Crypto ECDSA signature over a message's `digest` is r followed by s (IEEE P1363), each left-padded to the byte
// length of the group order. A signature of any other length verifies as false.
bool ecdsaSignDigest(EVP_PKEY*, std::span<const uint8_t> digest, SecretBytes& out);
bool ecdsaVerifyDigest(EVP_PKEY*, std::span<const uint8_t> signature, std::span<const uint8_t> digest, bool& out);
bool ed25519Sign(EVP_PKEY*, std::span<const uint8_t> data, SecretBytes& out);
bool ed25519Verify(EVP_PKEY*, std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out);
// ECDH or X25519: writes the first ceil(length_bits / 8) bytes of the shared secret to `out`, leaving the unused low
// bits of a partial last byte as derived; a zero length writes none after deriving the secret. A length longer than the
// secret, and an X25519 peer of small order, whose secret BoringSSL refuses as all zeros, fail.
bool deriveSharedSecret(EVP_PKEY* private_key, EVP_PKEY* public_key, size_t length_bits, SecretBytes& out);

}
