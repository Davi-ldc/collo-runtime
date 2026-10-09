// SHA-3 (FIPS 202) digests and HMAC computed by Collo's own Keccak sponge. Web Crypto digest, HMAC, and the message
// hash of RSA and ECDSA signatures use these. The EVP SHA-3 digests that Collo's BoringSSL patch exposes serve the
// paths that hand BoringSSL an EVP_MD: RSA padding, PBKDF2 and HKDF. The functions borrow their inputs and keep no
// state between calls, so they are safe on any thread. Each fails, returning false, when the hash is not a SHA-3 hash,
// `out` has the wrong size or allocation fails.

#pragma once

#include "host_functions/webapi/crypto/types.h"

#include <openssl/digest.h>
#include <wtf/Vector.h>

#include <array>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

bool isSha3Hash(WebCryptoHash);
bool sha3DigestBytes(const HashSpec&, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out);
bool sha3DigestRaw(const HashSpec&, std::span<const uint8_t> data, std::span<uint8_t> out);
bool sha3HmacRaw(const HashSpec&, std::span<const uint8_t> key, std::span<const uint8_t> data,
    std::array<uint8_t, EVP_MAX_MD_SIZE>& out, unsigned& out_len);

}
