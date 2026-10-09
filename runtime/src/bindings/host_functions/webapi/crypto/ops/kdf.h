// PBKDF2 and HKDF behind Web Crypto deriveBits and deriveKey, over BoringSSL. They take native data and touch no
// JavaScript value, so they run on whichever thread runs the crypto job: a crypto pool thread, or the VM thread for a
// job run inline. The inputs are borrowed for the call. `length_bits` must be a multiple of 8 and at most
// maxWebCryptoDerivedBytes in bytes, and PBKDF2 also fails on zero iterations. `out` must be empty, with no buffer, on
// entry; it holds the derived bytes on success and comes back empty and zeroed on failure.

#pragma once

#include "host_functions/webapi/crypto/types.h"

#include <wtf/Vector.h>

#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

bool derivePbkdf2BitsNative(std::span<const uint8_t> material, std::span<const uint8_t> salt, uint32_t iterations,
    WebCryptoHash, size_t length_bits, WTF::Vector<uint8_t>& out);
bool deriveHkdfBitsNative(std::span<const uint8_t> material, std::span<const uint8_t> salt,
    std::span<const uint8_t> info, WebCryptoHash, size_t length_bits, WTF::Vector<uint8_t>& out);

}
