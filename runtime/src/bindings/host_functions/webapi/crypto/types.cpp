// The hash table and the numeric range checks declared in `types.h`. The table is constant data and nothing here
// touches JSC, so any thread may call these functions.

#include "host_functions/webapi/crypto/types.h"

#include <openssl/digest.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <cmath>
#include <limits>
#include <type_traits>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    constexpr std::array allHashSpecs {
        HashSpec { WebCryptoHash::SHA1, "SHA-1"_s, EVP_sha1, 20, 512, "HS1"_s },
        HashSpec { WebCryptoHash::SHA224, "SHA-224"_s, EVP_sha224, 28, 512, "HS224"_s },
        HashSpec { WebCryptoHash::SHA256, "SHA-256"_s, EVP_sha256, 32, 512, "HS256"_s },
        HashSpec { WebCryptoHash::SHA384, "SHA-384"_s, EVP_sha384, 48, 1024, "HS384"_s },
        HashSpec { WebCryptoHash::SHA512, "SHA-512"_s, EVP_sha512, 64, 1024, "HS512"_s },
        HashSpec { WebCryptoHash::SHA3_224, "SHA3-224"_s, EVP_sha3_224, 28, 1152, ""_s },
        HashSpec { WebCryptoHash::SHA3_256, "SHA3-256"_s, EVP_sha3_256, 32, 1088, ""_s },
        HashSpec { WebCryptoHash::SHA3_384, "SHA3-384"_s, EVP_sha3_384, 48, 832, ""_s },
        HashSpec { WebCryptoHash::SHA3_512, "SHA3-512"_s, EVP_sha3_512, 64, 576, ""_s },
    };

} // namespace

bool checkedIntegerInRange(double number, double min, double max)
{
    return std::isfinite(number) && std::floor(number) == number && number >= min && number <= max;
}

bool checkedSizeFromNumber(double number, size_t min, size_t max, size_t& out)
{
    if (!checkedIntegerInRange(number, static_cast<double>(min), static_cast<double>(max)))
        return false;
    out = static_cast<size_t>(number);
    return true;
}

bool checkedUInt32FromNumber(double number, uint32_t min, uint32_t max, uint32_t& out)
{
    if (!checkedIntegerInRange(number, static_cast<double>(min), static_cast<double>(max)))
        return false;
    out = static_cast<uint32_t>(number);
    return true;
}

bool checkedUInt8FromNumber(double number, uint8_t min, uint8_t max, uint8_t& out)
{
    if (!checkedIntegerInRange(number, static_cast<double>(min), static_cast<double>(max)))
        return false;
    out = static_cast<uint8_t>(number);
    return true;
}

const HashSpec& hashSpec(WebCryptoHash hash)
{
    for (const auto& spec : allHashSpecs) {
        if (spec.id == hash)
            return spec;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

const HashSpec* hashSpecFromName(const WTF::String& name)
{
    for (const auto& spec : allHashSpecs) {
        if (WTF::equalIgnoringASCIICase(name, spec.name))
            return &spec;
    }
    return nullptr;
}

const EVP_MD* hashEvp(const HashSpec& hash)
{
    if (!hash.evp)
        return nullptr;
    return hash.evp();
}

bool hashHasOpenSslEvp(const HashSpec& hash) { return !!hashEvp(hash); }

static_assert(!std::is_copy_constructible_v<SecretBytes>);
static_assert(!std::is_copy_assignable_v<SecretBytes>);
static_assert(std::is_nothrow_move_constructible_v<SecretBytes>);
static_assert(std::is_nothrow_move_assignable_v<SecretBytes>);

}
