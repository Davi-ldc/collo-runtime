// The Keccak-f[1600] permutation and sponge behind sha3.h, with the SHA-3 domain padding of FIPS 202 and an HMAC whose
// block is the sponge rate. The sponge state and every scratch buffer can hold HMAC key material, so each is zeroed
// before it leaves scope.

#include "host_functions/webapi/crypto/ops/sha3.h"

#include <wtf/Assertions.h>
#include <wtf/StdLibExtras.h>

#include <algorithm>
#include <array>
#include <bit>
#include <cstring>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    constexpr std::array<uint64_t, 24> keccak_round_constants {
        0x0000000000000001ULL,
        0x0000000000008082ULL,
        0x800000000000808aULL,
        0x8000000080008000ULL,
        0x000000000000808bULL,
        0x0000000080000001ULL,
        0x8000000080008081ULL,
        0x8000000000008009ULL,
        0x000000000000008aULL,
        0x0000000000000088ULL,
        0x0000000080008009ULL,
        0x000000008000000aULL,
        0x000000008000808bULL,
        0x800000000000008bULL,
        0x8000000000008089ULL,
        0x8000000000008003ULL,
        0x8000000000008002ULL,
        0x8000000000000080ULL,
        0x000000000000800aULL,
        0x800000008000000aULL,
        0x8000000080008081ULL,
        0x8000000000008080ULL,
        0x0000000080000001ULL,
        0x8000000080008008ULL,
    };

    constexpr std::array<unsigned, 25> keccak_rotation_offsets {
        0,
        1,
        62,
        28,
        27,
        36,
        44,
        6,
        55,
        20,
        3,
        10,
        43,
        25,
        39,
        41,
        45,
        15,
        21,
        8,
        18,
        2,
        61,
        56,
        14,
    };

    constexpr size_t sha3RateBytes(WebCryptoHash hash)
    {
        switch (hash) {
        case WebCryptoHash::SHA3_224:
            return 144;
        case WebCryptoHash::SHA3_256:
            return 136;
        case WebCryptoHash::SHA3_384:
            return 104;
        case WebCryptoHash::SHA3_512:
            return 72;
        case WebCryptoHash::SHA1:
        case WebCryptoHash::SHA224:
        case WebCryptoHash::SHA256:
        case WebCryptoHash::SHA384:
        case WebCryptoHash::SHA512:
            return 0;
        }
        return 0;
    }

    void xorStateByte(std::array<uint64_t, 25>& state, size_t offset, uint8_t byte)
    {
        state[offset / 8] ^= static_cast<uint64_t>(byte) << ((offset % 8) * 8);
    }

    uint8_t readStateByte(const std::array<uint64_t, 25>& state, size_t offset)
    {
        return static_cast<uint8_t>((state[offset / 8] >> ((offset % 8) * 8)) & 0xff);
    }

    void keccakF1600(std::array<uint64_t, 25>& state)
    {
        std::array<uint64_t, 5> column;
        std::array<uint64_t, 5> delta;
        std::array<uint64_t, 25> rotated;

        for (uint64_t round_constant : keccak_round_constants) {
            for (size_t x = 0; x < 5; ++x) {
                column[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
            }
            for (size_t x = 0; x < 5; ++x)
                delta[x] = column[(x + 4) % 5] ^ std::rotl(column[(x + 1) % 5], 1);
            for (size_t y = 0; y < 5; ++y) {
                for (size_t x = 0; x < 5; ++x)
                    state[x + 5 * y] ^= delta[x];
            }

            for (size_t y = 0; y < 5; ++y) {
                for (size_t x = 0; x < 5; ++x) {
                    const size_t source = x + 5 * y;
                    const size_t target = y + 5 * ((2 * x + 3 * y) % 5);
                    rotated[target] = std::rotl(state[source], keccak_rotation_offsets[source]);
                }
            }

            for (size_t y = 0; y < 5; ++y) {
                for (size_t x = 0; x < 5; ++x) {
                    state[x + 5 * y]
                        = rotated[x + 5 * y] ^ ((~rotated[((x + 1) % 5) + 5 * y]) & rotated[((x + 2) % 5) + 5 * y]);
                }
            }

            state[0] ^= round_constant;
        }

        // These scratch buffers hold mixes of the sponge state, which absorbs HMAC key material, so they are zeroed
        // before the function returns.
        WTF::secureZeroSpan(std::span<uint64_t> { column.data(), column.size() });
        WTF::secureZeroSpan(std::span<uint64_t> { delta.data(), delta.size() });
        WTF::secureZeroSpan(std::span<uint64_t> { rotated.data(), rotated.size() });
    }

    class Sha3Context {
    public:
        explicit Sha3Context(size_t rate_bytes)
            : m_rate_bytes(rate_bytes)
        {
            ASSERT(rate_bytes > 0);
            ASSERT(rate_bytes <= 200);
        }

        ~Sha3Context()
        {
            // The sponge state absorbs the HMAC pads, which carry the key, so the destructor zeroes it.
            WTF::secureZeroSpan(std::span<uint64_t> { m_state.data(), m_state.size() });
        }

        void update(std::span<const uint8_t> input)
        {
            auto remaining = input;
            while (!remaining.empty()) {
                const size_t available = m_rate_bytes - m_offset;
                const size_t take = std::min(available, remaining.size());
                for (size_t index = 0; index < take; ++index)
                    xorStateByte(m_state, m_offset + index, remaining[index]);
                m_offset += take;
                remaining = remaining.subspan(take);

                if (m_offset == m_rate_bytes) {
                    keccakF1600(m_state);
                    m_offset = 0;
                }
            }
        }

        void finish(std::span<uint8_t> out)
        {
            xorStateByte(m_state, m_offset, 0x06);
            xorStateByte(m_state, m_rate_bytes - 1, 0x80);
            keccakF1600(m_state);

            for (size_t index = 0; index < out.size(); ++index)
                out[index] = readStateByte(m_state, index);
        }

    private:
        std::array<uint64_t, 25> m_state {};
        size_t m_rate_bytes { 0 };
        size_t m_offset { 0 };
    };

} // namespace

bool isSha3Hash(WebCryptoHash hash) { return sha3RateBytes(hash) != 0; }

bool sha3DigestRaw(const HashSpec& hash, std::span<const uint8_t> data, std::span<uint8_t> out)
{
    if (!isSha3Hash(hash.id))
        return false;
    if (out.size() != hash.digest_bytes)
        return false;

    Sha3Context context(sha3RateBytes(hash.id));
    context.update(data);
    context.finish(out);
    return true;
}

bool sha3DigestBytes(const HashSpec& hash, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out)
{
    if (!out.tryReserveInitialCapacity(hash.digest_bytes))
        return false;
    out.grow(hash.digest_bytes);
    if (sha3DigestRaw(hash, data, out.mutableSpan()))
        return true;
    out.clear();
    return false;
}

bool sha3HmacRaw(const HashSpec& hash, std::span<const uint8_t> key, std::span<const uint8_t> data,
    std::array<uint8_t, EVP_MAX_MD_SIZE>& out, unsigned& out_len)
{
    if (!isSha3Hash(hash.id))
        return false;

    const size_t block_bytes = sha3RateBytes(hash.id);
    std::array<uint8_t, 200> key_block {};
    std::array<uint8_t, EVP_MAX_MD_SIZE> key_digest {};

    if (key.size() > block_bytes) {
        if (!sha3DigestRaw(hash, key, std::span<uint8_t> { key_digest.data(), hash.digest_bytes }))
            return false;
        std::memcpy(key_block.data(), key_digest.data(), hash.digest_bytes);
    } else if (!key.empty()) {
        std::memcpy(key_block.data(), key.data(), key.size());
    }

    std::array<uint8_t, 200> inner_pad {};
    std::array<uint8_t, 200> outer_pad {};
    for (size_t index = 0; index < block_bytes; ++index) {
        inner_pad[index] = key_block[index] ^ 0x36;
        outer_pad[index] = key_block[index] ^ 0x5c;
    }

    std::array<uint8_t, EVP_MAX_MD_SIZE> inner_digest {};
    Sha3Context inner(sha3RateBytes(hash.id));
    inner.update(std::span<const uint8_t> { inner_pad.data(), block_bytes });
    inner.update(data);
    inner.finish(std::span<uint8_t> { inner_digest.data(), hash.digest_bytes });

    Sha3Context outer(sha3RateBytes(hash.id));
    outer.update(std::span<const uint8_t> { outer_pad.data(), block_bytes });
    outer.update(std::span<const uint8_t> { inner_digest.data(), hash.digest_bytes });
    outer.finish(std::span<uint8_t> { out.data(), hash.digest_bytes });

    out_len = static_cast<unsigned>(hash.digest_bytes);
    WTF::secureZeroSpan(std::span<uint8_t> { key_block.data(), key_block.size() });
    WTF::secureZeroSpan(std::span<uint8_t> { key_digest.data(), key_digest.size() });
    WTF::secureZeroSpan(std::span<uint8_t> { inner_pad.data(), inner_pad.size() });
    WTF::secureZeroSpan(std::span<uint8_t> { outer_pad.data(), outer_pad.size() });
    WTF::secureZeroSpan(std::span<uint8_t> { inner_digest.data(), inner_digest.size() });
    return true;
}

} // namespace Collo::HostFunctions::WebCrypto
