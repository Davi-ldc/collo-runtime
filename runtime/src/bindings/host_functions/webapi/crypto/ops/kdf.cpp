// PBKDF2 and HKDF through BoringSSL's PKCS5_PBKDF2_HMAC and HKDF, under the contract in kdf.h.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/ops/kdf.h"

#include <openssl/hkdf.h>
#include <openssl/evp.h>

namespace Collo::HostFunctions::WebCrypto {

static bool clearOutputAndFail(SecretBytes& out)
{
    out.clear();
    return false;
}

bool derivePbkdf2BitsNative(std::span<const uint8_t> material, std::span<const uint8_t> salt, uint32_t iterations,
    WebCryptoHash hash, size_t length_bits, SecretBytes& out)
{
    if (!iterations)
        return false;
    // The deriveBits and deriveKey front ends already reject a length that is not a multiple of 8. Failing here as
    // well keeps any other caller from getting a silently truncated result.
    if (length_bits % 8)
        return false;
    auto byte_length = length_bits / 8;
    if (byte_length > maxWebCryptoDerivedBytes)
        return false;
    auto* evp = hashEvp(hashSpec(hash));
    if (!evp)
        return false;
    if (!out.tryGrow(byte_length))
        return false;
    if (PKCS5_PBKDF2_HMAC(reinterpret_cast<const char*>(material.data()), material.size(), salt.data(), salt.size(),
            iterations, evp, out.size(), out.data())
        != 1)
        return clearOutputAndFail(out);
    return true;
}

bool deriveHkdfBitsNative(std::span<const uint8_t> material, std::span<const uint8_t> salt,
    std::span<const uint8_t> info, WebCryptoHash hash, size_t length_bits, SecretBytes& out)
{
    // As in derivePbkdf2BitsNative, a length that is not a multiple of 8 fails instead of truncating.
    if (length_bits % 8)
        return false;
    auto byte_length = length_bits / 8;
    if (byte_length > maxWebCryptoDerivedBytes)
        return false;
    auto* evp = hashEvp(hashSpec(hash));
    if (!evp)
        return false;
    if (!out.tryGrow(byte_length))
        return false;
    if (HKDF(out.data(), out.size(), evp, material.data(), material.size(), salt.data(), salt.size(), info.data(),
            info.size())
        != 1)
        return clearOutputAndFail(out);
    return true;
}

} // namespace Collo::HostFunctions::WebCrypto
