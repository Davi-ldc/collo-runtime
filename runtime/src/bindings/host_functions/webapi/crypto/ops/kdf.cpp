// PBKDF2 (RFC 8018, section 5.2) and HKDF (RFC 5869) under the contract in kdf.h, as loops over an HMAC_CTX so the
// guard can stop them between steps: BoringSSL's PKCS5_PBKDF2_HMAC and HKDF run to the end in one call. Each keys its
// HMAC once and restarts it per step with HMAC_Init_ex and a null key, which reuses the key, as BoringSSL's own loops
// do. A length that is not a multiple of 8 fails instead of truncating, whatever the caller checked.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/ops/kdf.h"

#include "host_functions/webapi/crypto/ops/symmetric.h"

#include <openssl/hmac.h>
#include <openssl/mem.h>

#include <algorithm>
#include <array>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    // The PBKDF2 iterations between two spends on the guard: about 0.25 ms of SHA-256 and 2 ms of SHA3-512 on the
    // reference machine (budget.cpp).
    constexpr uint32_t pbkdf2_iterations_per_slice = 1024;

    // RFC 5869 caps HKDF's output at 255 blocks of the hash.
    constexpr size_t hkdf_blocks_max = 255;

    // Restarts a keyed `ctx` for the next message under the same key.
    bool restartHmac(HMAC_CTX* ctx) { return HMAC_Init_ex(ctx, nullptr, 0, nullptr, nullptr) == 1; }

} // namespace

bool derivePbkdf2Bits(std::span<const uint8_t> material, std::span<const uint8_t> salt, uint32_t iterations,
    const HashSpec& hash, size_t length_bits, SecretBytes& out, TimeGuard& guard)
{
    if (!iterations || length_bits % 8 || length_bits / 8 > derived_bytes_max)
        return false;
    if (!out.tryGrow(length_bits / 8))
        return false;
    bssl::ScopedHMAC_CTX ctx;
    std::array<uint8_t, EVP_MAX_MD_SIZE> chained {};
    const size_t digest_bytes = hash.digest_bytes;
    bool derived = hmacInit(ctx.get(), hash, material, guard);
    size_t offset = 0;
    for (uint32_t block_index = 1; derived && offset < out.size(); ++block_index) {
        // U_1 = PRF(password, salt || INT(i)), and the block starts as U_1.
        const std::array<uint8_t, 4> index_bytes { static_cast<uint8_t>(block_index >> 24),
            static_cast<uint8_t>(block_index >> 16), static_cast<uint8_t>(block_index >> 8),
            static_cast<uint8_t>(block_index) };
        unsigned chained_len = 0;
        derived = restartHmac(ctx.get()) && hmacUpdate(ctx.get(), hash, salt, guard)
            && HMAC_Update(ctx.get(), index_bytes.data(), index_bytes.size()) == 1
            && HMAC_Final(ctx.get(), chained.data(), &chained_len) == 1;
        if (!derived)
            break;
        auto block = out.mutableSpan().subspan(offset, std::min(digest_bytes, out.size() - offset));
        std::copy_n(chained.begin(), block.size(), block.begin());
        // U_j = PRF(password, U_{j-1}), and the block is the XOR of every U_j.
        for (uint32_t iteration = 1; derived && iteration < iterations; ++iteration) {
            if (!(iteration % pbkdf2_iterations_per_slice)) {
                derived = guard.spend(
                    pbkdf2IterationsNs(hash.id, std::min(pbkdf2_iterations_per_slice, iterations - iteration)));
                if (!derived)
                    break;
            }
            derived = restartHmac(ctx.get()) && HMAC_Update(ctx.get(), chained.data(), digest_bytes) == 1
                && HMAC_Final(ctx.get(), chained.data(), &chained_len) == 1;
            for (size_t index = 0; derived && index < block.size(); ++index)
                block[index] ^= chained[index];
        }
        offset += block.size();
    }
    OPENSSL_cleanse(chained.data(), chained.size());
    return derived || clearAndFail(out);
}

bool deriveHkdfBits(std::span<const uint8_t> material, std::span<const uint8_t> salt, std::span<const uint8_t> info,
    const HashSpec& hash, size_t length_bits, SecretBytes& out, TimeGuard& guard)
{
    const size_t digest_bytes = hash.digest_bytes;
    if (length_bits % 8 || length_bits / 8 > derived_bytes_max || length_bits / 8 > hkdf_blocks_max * digest_bytes)
        return false;
    if (!out.tryGrow(length_bits / 8))
        return false;
    std::array<uint8_t, EVP_MAX_MD_SIZE> pseudorandom_key {};
    std::array<uint8_t, EVP_MAX_MD_SIZE> previous {};
    unsigned written = 0;

    // Extract: PRK = HMAC(salt, IKM). An empty salt keys HMAC with zeros, the default RFC 5869 gives it.
    bssl::ScopedHMAC_CTX extract;
    bool derived = hmacInit(extract.get(), hash, salt, guard) && hmacUpdate(extract.get(), hash, material, guard)
        && HMAC_Final(extract.get(), pseudorandom_key.data(), &written) == 1;

    // Expand: T(i) = HMAC(PRK, T(i-1) || info || i), with T(0) empty, and the output the T(i) in order.
    bssl::ScopedHMAC_CTX expand;
    derived = derived && HMAC_Init_ex(expand.get(), pseudorandom_key.data(), digest_bytes, hash.evp(), nullptr) == 1;
    size_t offset = 0;
    for (size_t block_index = 1; derived && offset < out.size(); ++block_index) {
        const auto counter = static_cast<uint8_t>(block_index);
        derived = (block_index == 1
                      || (restartHmac(expand.get()) && HMAC_Update(expand.get(), previous.data(), digest_bytes) == 1))
            && hmacUpdate(expand.get(), hash, info, guard) && HMAC_Update(expand.get(), &counter, 1) == 1
            && HMAC_Final(expand.get(), previous.data(), &written) == 1;
        if (!derived)
            break;
        const size_t block_bytes = std::min(digest_bytes, out.size() - offset);
        std::copy_n(previous.begin(), block_bytes, out.mutableSpan().begin() + offset);
        offset += block_bytes;
    }
    OPENSSL_cleanse(pseudorandom_key.data(), pseudorandom_key.size());
    OPENSSL_cleanse(previous.data(), previous.size());
    return derived || clearAndFail(out);
}

}
