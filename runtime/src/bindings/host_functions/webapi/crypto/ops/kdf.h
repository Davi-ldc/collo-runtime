// PBKDF2 and HKDF behind Web Crypto deriveBits and deriveKey, over BoringSSL's HMAC. They take native data and touch no
// JavaScript value; the SubtleCrypto methods call them on the VM thread. The inputs are borrowed for the call.
// `length_bits` must be a multiple of 8 and at most `derived_bytes_max` in bytes, HKDF's also at most 255 hash blocks
// (RFC 5869), and PBKDF2 also fails on zero iterations. `out` must be empty on entry; it holds the derived bytes on
// success and comes back empty on failure, its buffer zeroed and freed.
//
// Both spend their work on the caller's `TimeGuard` (budget.h) as they go, every few iterations and every slice of a
// hashed input, and fail once it refuses.

#pragma once

#include "host_functions/webapi/crypto/budget.h"
#include "host_functions/webapi/crypto/types.h"

#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

bool derivePbkdf2Bits(std::span<const uint8_t> material, std::span<const uint8_t> salt, uint32_t iterations,
    const HashSpec&, size_t length_bits, SecretBytes& out, TimeGuard&);
bool deriveHkdfBits(std::span<const uint8_t> material, std::span<const uint8_t> salt, std::span<const uint8_t> info,
    const HashSpec&, size_t length_bits, SecretBytes& out, TimeGuard&);

}
