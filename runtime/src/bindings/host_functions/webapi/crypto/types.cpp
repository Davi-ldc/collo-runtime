// The hash table declared in types.h. It is constant data in the zygote's read-only pages, and nothing here touches
// JSC.

#include "host_functions/webapi/crypto/types.h"

#include <openssl/digest.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <type_traits>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    // Indexed by WebCryptoHash; the static_assert below holds the order.
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

    constexpr bool hashTableFollowsEnumOrder()
    {
        for (size_t index = 0; index < allHashSpecs.size(); ++index) {
            if (static_cast<size_t>(allHashSpecs[index].id) != index)
                return false;
        }
        return true;
    }

    static_assert(hashTableFollowsEnumOrder());
    // HMAC with a SHA-3 hash keys a block of the hash's rate, which BoringSSL's HMAC holds only because the patch
    // series raises EVP_MAX_MD_BLOCK_SIZE to SHA3-224's 144 bytes.
    static_assert(EVP_MAX_MD_BLOCK_SIZE * 8 >= 1152);

} // namespace

const HashSpec& hashSpec(WebCryptoHash hash) { return allHashSpecs[static_cast<size_t>(hash)]; }

const HashSpec* hashSpecFromName(const WTF::String& name)
{
    for (const auto& spec : allHashSpecs) {
        if (WTF::equalIgnoringASCIICase(name, spec.name))
            return &spec;
    }
    return nullptr;
}

static_assert(!std::is_copy_constructible_v<SecretBytes>);
static_assert(!std::is_copy_assignable_v<SecretBytes>);
static_assert(std::is_nothrow_move_constructible_v<SecretBytes>);
static_assert(std::is_nothrow_move_assignable_v<SecretBytes>);

}
