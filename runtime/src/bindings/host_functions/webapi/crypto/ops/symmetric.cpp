// Digests, HMAC and AES behind symmetric.h, which states the output contract and the slicing. Digests and HMAC run
// BoringSSL's EVP digests for every hash, the SHA-3 ones included. GCM, CBC and CTR with a full 128-bit counter use
// BoringSSL's EVP ciphers, fed in slices. BoringSSL has no 8-bit CFB and no CTR with a narrower counter, so those, like
// key wrap, use the AES_KEY functions of aes.h. Every expanded AES_KEY and keystream buffer is cleansed before it
// leaves scope.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/ops/symmetric.h"

#include <openssl/aes.h>
#include <openssl/cipher.h>
#include <openssl/digest.h>
#include <openssl/hmac.h>
#include <openssl/mem.h>
#include <wtf/Assertions.h>
#include <wtf/StdLibExtras.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <optional>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    // The input a digest or HMAC hashes per call: about 0.6 ms of SHA3-512, the slowest hash, on the reference
    // machine (budget.cpp).
    constexpr size_t hash_slice_bytes = 64 * 1024;
    // The input an EVP cipher takes per call: about 0.5 ms of AES-CBC encryption, its slowest mode there.
    constexpr size_t cipher_slice_bytes = 256 * 1024;
    // The AES blocks the 8-bit CFB and partial-block CTR loops run per slice: about 0.25 ms there.
    constexpr size_t aes_slice_blocks = 4096;
    // The EVP update functions take an int length.
    static_assert(cipher_slice_bytes <= static_cast<size_t>(std::numeric_limits<int>::max()));

    // Calls `step` with each slice of `data` of at most `slice_bytes`, in order, and stops at the first it refuses.
    template <typename Step> bool forEachSlice(std::span<const uint8_t> data, size_t slice_bytes, const Step& step)
    {
        for (size_t offset = 0; offset < data.size(); offset += slice_bytes) {
            if (!step(data.subspan(offset, std::min(slice_bytes, data.size() - offset))))
                return false;
        }
        return true;
    }

    enum class EvpAesMode : uint8_t {
        Ctr,
        Cbc,
        Gcm,
    };

    // Rows CTR, CBC and GCM; columns 128-, 192- and 256-bit keys.
    constexpr std::array<std::array<const EVP_CIPHER* (*)(), 3>, 3> evp_aes_ciphers { {
        { EVP_aes_128_ctr, EVP_aes_192_ctr, EVP_aes_256_ctr },
        { EVP_aes_128_cbc, EVP_aes_192_cbc, EVP_aes_256_cbc },
        { EVP_aes_128_gcm, EVP_aes_192_gcm, EVP_aes_256_gcm },
    } };

    // Null for a key length AES does not have.
    const EVP_CIPHER* evpAesCipher(EvpAesMode mode, size_t key_bytes)
    {
        if (!isValidAesKeyLength(key_bytes))
            return nullptr;
        return evp_aes_ciphers[static_cast<size_t>(mode)][(key_bytes - 16) / 8]();
    }

    // EVP_CTRL_GCM_SET_IVLEN takes the IV's length as an int.
    bool fitsGcmIv(size_t byte_length) { return byte_length <= static_cast<size_t>(std::numeric_limits<int>::max()); }

    // Runs EVP_CipherUpdate over `input` in slices, each once `guard` admits it, writing the output from `output` on;
    // a null `output` passes the input as GCM additional data. Returns the bytes written, or no value when an update
    // fails or the guard refuses. `output` has room for the input plus one block.
    std::optional<size_t> cipherUpdate(
        EVP_CIPHER_CTX* ctx, AesMode mode, std::span<const uint8_t> input, uint8_t* output, TimeGuard& guard)
    {
        size_t written = 0;
        const bool updated = forEachSlice(input, cipher_slice_bytes, [&](std::span<const uint8_t> slice) {
            if (!guard.spend(aesWorstCaseNs(mode, slice.size())))
                return false;
            int slice_written = 0;
            if (EVP_CipherUpdate(ctx, output ? output + written : nullptr, &slice_written, slice.data(),
                    static_cast<int>(slice.size()))
                != 1)
                return false;
            if (output)
                written += static_cast<size_t>(slice_written);
            return true;
        });
        if (!updated)
            return std::nullopt;
        return written;
    }

    // CFB with 8-bit feedback: each output byte is the input byte XOR the first byte of AES applied to the last 16
    // feedback bytes, and the ciphertext byte joins the feedback. shift_register holds that window at offset `shift`;
    // each new byte lands at 16 + shift, and after 16 of them the newer half moves to the front.
    bool aesCfb8Transform(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> input,
        bool encrypt, SecretBytes& out, TimeGuard& guard)
    {
        if (!isValidAesKeyLength(key.size()) || iv.size() != 16)
            return false;
        if (!out.tryGrow(input.size()))
            return false;

        AES_KEY aes_key;
        std::array<uint8_t, 32> shift_register {};
        std::array<uint8_t, 16> encrypted_block {};
        bool transformed = AES_set_encrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) >= 0;
        std::copy(iv.begin(), iv.end(), shift_register.begin());
        size_t shift = 0;
        for (size_t index = 0; transformed && index < input.size(); ++index) {
            if (!(index % aes_slice_blocks)) {
                transformed
                    = guard.spend(aesWorstCaseNs(AesMode::Cfb8, std::min(aes_slice_blocks, input.size() - index)));
                if (!transformed)
                    break;
            }
            AES_encrypt(shift_register.data() + shift, encrypted_block.data(), &aes_key);
            const auto output_byte = static_cast<uint8_t>(input[index] ^ encrypted_block[0]);
            out.mutableSpan()[index] = output_byte;
            shift_register[16 + shift] = encrypt ? output_byte : input[index];
            ++shift;
            if (shift == 16) {
                std::memcpy(shift_register.data(), shift_register.data() + 16, 16);
                shift = 0;
            }
        }

        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        WTF::secureZeroSpan(std::span<uint8_t> { shift_register.data(), shift_register.size() });
        WTF::secureZeroSpan(std::span<uint8_t> { encrypted_block.data(), encrypted_block.size() });
        return transformed || clearAndFail(out);
    }

    // Adds one to the rightmost `counter_bits` bits of the counter block, modulo 2^counter_bits, and leaves the other
    // bits alone.
    void incrementAesCtrCounter(std::array<uint8_t, 16>& counter, uint8_t counter_bits)
    {
        size_t bits_remaining = counter_bits;
        for (int index = 15; index >= 0 && bits_remaining; --index) {
            auto bits_in_byte = std::min<size_t>(bits_remaining, 8);
            uint16_t mask = bits_in_byte == 8 ? 0xff : static_cast<uint16_t>((1u << bits_in_byte) - 1);
            uint16_t value = static_cast<uint16_t>(counter[index] & mask) + 1;
            counter[index] = static_cast<uint8_t>((counter[index] & ~mask) | (value & mask));
            if (value <= mask)
                return;
            bits_remaining -= bits_in_byte;
        }
    }

    bool aesCtrTransformWholeBlock(std::span<const uint8_t> key, std::span<const uint8_t> counter,
        std::span<const uint8_t> input, SecretBytes& out, TimeGuard& guard)
    {
        const EVP_CIPHER* cipher = evpAesCipher(EvpAesMode::Ctr, key.size());
        if (!cipher || counter.size() != 16)
            return false;
        if (input.empty())
            return true;
        if (!out.tryGrow(input.size()))
            return false;

        bssl::ScopedEVP_CIPHER_CTX ctx;
        if (!EVP_EncryptInit_ex(ctx.get(), cipher, nullptr, key.data(), counter.data()))
            return clearAndFail(out);
        auto written = cipherUpdate(ctx.get(), AesMode::CtrWholeBlock, input, out.mutableSpan().data(), guard);
        if (!written)
            return clearAndFail(out);
        int final_written_int = 0;
        if (EVP_EncryptFinal_ex(ctx.get(), out.mutableSpan().data() + *written, &final_written_int) != 1)
            return clearAndFail(out);
        if (*written + static_cast<size_t>(final_written_int) != out.size())
            return clearAndFail(out);
        return true;
    }

    bool aesCtrTransformPartialBlock(std::span<const uint8_t> key, std::span<const uint8_t> counter_block,
        uint8_t counter_bits, std::span<const uint8_t> input, SecretBytes& out, TimeGuard& guard)
    {
        if (!out.tryGrow(input.size()))
            return false;
        AES_KEY aes_key;
        std::array<uint8_t, 16> counter;
        std::copy(counter_block.begin(), counter_block.end(), counter.begin());
        std::array<uint8_t, 16> stream_block {};
        bool transformed = AES_set_encrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) >= 0;
        for (size_t offset = 0; transformed && offset < input.size(); offset += 16) {
            if (!((offset / 16) % aes_slice_blocks)) {
                const size_t slice_bytes = std::min(aes_slice_blocks * 16, input.size() - offset);
                transformed = guard.spend(aesWorstCaseNs(AesMode::CtrPartialBlock, slice_bytes));
                if (!transformed)
                    break;
            }
            AES_encrypt(counter.data(), stream_block.data(), &aes_key);
            auto chunk = std::min<size_t>(16, input.size() - offset);
            for (size_t index = 0; index < chunk; ++index)
                out.mutableSpan()[offset + index] = static_cast<uint8_t>(input[offset + index] ^ stream_block[index]);
            incrementAesCtrCounter(counter, counter_bits);
        }

        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        WTF::secureZeroSpan(std::span<uint8_t> { stream_block.data(), stream_block.size() });
        return transformed || clearAndFail(out);
    }

    // Feeds `data` to `update`, a digest's or an HMAC's update call, in slices of `hash_slice_bytes`, each once `guard`
    // admits it.
    template <typename Update>
    bool hashUpdate(const HashSpec& hash, std::span<const uint8_t> data, TimeGuard& guard, const Update& update)
    {
        return forEachSlice(data, hash_slice_bytes, [&](std::span<const uint8_t> slice) {
            return guard.spend(digestWorstCaseNs(hash.id, slice.size())) && update(slice);
        });
    }

} // namespace

bool digestBytes(
    const HashSpec& hash, std::span<const uint8_t> data, std::array<uint8_t, EVP_MAX_MD_SIZE>& out, TimeGuard& guard)
{
    bssl::ScopedEVP_MD_CTX ctx;
    if (EVP_DigestInit_ex(ctx.get(), hash.evp(), nullptr) != 1)
        return false;
    const bool hashed = hashUpdate(hash, data, guard,
        [&](std::span<const uint8_t> slice) { return EVP_DigestUpdate(ctx.get(), slice.data(), slice.size()) == 1; });
    unsigned digest_len = 0;
    return hashed && EVP_DigestFinal_ex(ctx.get(), out.data(), &digest_len) == 1 && digest_len == hash.digest_bytes;
}

bool hmacInit(HMAC_CTX* ctx, const HashSpec& hash, std::span<const uint8_t> key, TimeGuard& guard)
{
    const EVP_MD* md = hash.evp();
    if (key.size() <= EVP_MD_block_size(md))
        return HMAC_Init_ex(ctx, key.data(), key.size(), md, nullptr) == 1;
    std::array<uint8_t, EVP_MAX_MD_SIZE> hashed_key;
    const bool keyed = digestBytes(hash, key, hashed_key, guard)
        && HMAC_Init_ex(ctx, hashed_key.data(), hash.digest_bytes, md, nullptr) == 1;
    OPENSSL_cleanse(hashed_key.data(), hashed_key.size());
    return keyed;
}

bool hmacUpdate(HMAC_CTX* ctx, const HashSpec& hash, std::span<const uint8_t> data, TimeGuard& guard)
{
    return hashUpdate(hash, data, guard,
        [&](std::span<const uint8_t> slice) { return HMAC_Update(ctx, slice.data(), slice.size()) == 1; });
}

bool hmacSign(const HashSpec& hash, std::span<const uint8_t> key, std::span<const uint8_t> data,
    std::array<uint8_t, EVP_MAX_MD_SIZE>& out, TimeGuard& guard)
{
    bssl::ScopedHMAC_CTX ctx;
    unsigned out_len = 0;
    return hmacInit(ctx.get(), hash, key, guard) && hmacUpdate(ctx.get(), hash, data, guard)
        && HMAC_Final(ctx.get(), out.data(), &out_len) == 1 && out_len == hash.digest_bytes;
}

bool isValidAesKeyLength(size_t byte_length) { return byte_length == 16 || byte_length == 24 || byte_length == 32; }

bool aesGcmEncrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> additional_data,
    size_t tag_bytes, std::span<const uint8_t> plaintext, SecretBytes& out, TimeGuard& guard)
{
    const EVP_CIPHER* cipher = evpAesCipher(EvpAesMode::Gcm, key.size());
    if (!cipher || iv.empty() || !fitsGcmIv(iv.size()) || tag_bytes > 16)
        return false;
    if (!out.tryGrow(plaintext.size() + tag_bytes))
        return false;

    // The context hashes an IV that is not 12 bytes long when it takes it.
    if (!guard.spend(aesGcmWorstCaseNs(0, 0, iv.size())))
        return clearAndFail(out);
    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_EncryptInit_ex(ctx.get(), cipher, nullptr, nullptr, nullptr))
        return clearAndFail(out);
    if (!EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(iv.size()), nullptr))
        return clearAndFail(out);
    if (!EVP_EncryptInit_ex(ctx.get(), nullptr, nullptr, key.data(), iv.data()))
        return clearAndFail(out);
    if (!cipherUpdate(ctx.get(), AesMode::Gcm, additional_data, nullptr, guard))
        return clearAndFail(out);
    auto written = cipherUpdate(ctx.get(), AesMode::Gcm, plaintext, out.mutableSpan().data(), guard);
    if (!written)
        return clearAndFail(out);
    int final_written_int = 0;
    if (EVP_EncryptFinal_ex(ctx.get(), out.mutableSpan().data() + *written, &final_written_int) != 1)
        return clearAndFail(out);
    const size_t total_written = *written + static_cast<size_t>(final_written_int);
    if (total_written + tag_bytes != out.size())
        return clearAndFail(out);
    if (!EVP_CIPHER_CTX_ctrl(
            ctx.get(), EVP_CTRL_GCM_GET_TAG, static_cast<int>(tag_bytes), out.mutableSpan().data() + total_written))
        return clearAndFail(out);
    return true;
}

bool aesGcmDecrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> additional_data,
    size_t tag_bytes, std::span<const uint8_t> ciphertext_and_tag, SecretBytes& out, TimeGuard& guard)
{
    const EVP_CIPHER* cipher = evpAesCipher(EvpAesMode::Gcm, key.size());
    if (!cipher || iv.empty() || !fitsGcmIv(iv.size()) || tag_bytes > 16 || ciphertext_and_tag.size() < tag_bytes)
        return false;
    const size_t ciphertext_len = ciphertext_and_tag.size() - tag_bytes;
    auto ciphertext = ciphertext_and_tag.first(ciphertext_len);
    auto tag = ciphertext_and_tag.subspan(ciphertext_len, tag_bytes);
    if (!out.tryGrow(ciphertext_len))
        return false;

    // The context hashes an IV that is not 12 bytes long when it takes it.
    if (!guard.spend(aesGcmWorstCaseNs(0, 0, iv.size())))
        return clearAndFail(out);
    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_DecryptInit_ex(ctx.get(), cipher, nullptr, nullptr, nullptr))
        return clearAndFail(out);
    if (!EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(iv.size()), nullptr))
        return clearAndFail(out);
    if (!EVP_DecryptInit_ex(ctx.get(), nullptr, nullptr, key.data(), iv.data()))
        return clearAndFail(out);
    // BoringSSL takes the expected tag at any point before EVP_DecryptFinal_ex, which compares it and fails on a
    // mismatch.
    if (!EVP_CIPHER_CTX_ctrl(
            ctx.get(), EVP_CTRL_GCM_SET_TAG, static_cast<int>(tag_bytes), const_cast<uint8_t*>(tag.data())))
        return clearAndFail(out);
    if (!cipherUpdate(ctx.get(), AesMode::Gcm, additional_data, nullptr, guard))
        return clearAndFail(out);
    auto written = cipherUpdate(ctx.get(), AesMode::Gcm, ciphertext, out.mutableSpan().data(), guard);
    if (!written)
        return clearAndFail(out);
    int final_written_int = 0;
    if (EVP_DecryptFinal_ex(ctx.get(), out.mutableSpan().data() + *written, &final_written_int) != 1)
        return clearAndFail(out);
    out.shrink(*written + static_cast<size_t>(final_written_int));
    return true;
}

bool aesCbcEncrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> plaintext,
    SecretBytes& out, TimeGuard& guard)
{
    const EVP_CIPHER* cipher = evpAesCipher(EvpAesMode::Cbc, key.size());
    if (!cipher || iv.size() != 16)
        return false;
    if (!out.tryGrow(plaintext.size() + 16))
        return false;

    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_EncryptInit_ex(ctx.get(), cipher, nullptr, key.data(), iv.data()))
        return clearAndFail(out);
    auto written = cipherUpdate(ctx.get(), AesMode::Cbc, plaintext, out.mutableSpan().data(), guard);
    if (!written)
        return clearAndFail(out);
    int final_written_int = 0;
    if (EVP_EncryptFinal_ex(ctx.get(), out.mutableSpan().data() + *written, &final_written_int) != 1)
        return clearAndFail(out);
    out.shrink(*written + static_cast<size_t>(final_written_int));
    return true;
}

bool aesCbcDecrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> ciphertext,
    SecretBytes& out, TimeGuard& guard)
{
    const EVP_CIPHER* cipher = evpAesCipher(EvpAesMode::Cbc, key.size());
    if (!cipher || iv.size() != 16 || ciphertext.empty() || (ciphertext.size() % 16))
        return false;
    if (!out.tryGrow(ciphertext.size()))
        return false;

    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_DecryptInit_ex(ctx.get(), cipher, nullptr, key.data(), iv.data()))
        return clearAndFail(out);
    // Decryption holds back its last block until EVP_DecryptFinal_ex, so what the updates write never runs past the
    // ciphertext's length.
    auto written = cipherUpdate(ctx.get(), AesMode::Cbc, ciphertext, out.mutableSpan().data(), guard);
    if (!written)
        return clearAndFail(out);
    int final_written_int = 0;
    if (EVP_DecryptFinal_ex(ctx.get(), out.mutableSpan().data() + *written, &final_written_int) != 1)
        return clearAndFail(out);
    out.shrink(*written + static_cast<size_t>(final_written_int));
    return true;
}

bool aesCfb8Encrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> plaintext,
    SecretBytes& out, TimeGuard& guard)
{
    return aesCfb8Transform(key, iv, plaintext, true, out, guard);
}

bool aesCfb8Decrypt(std::span<const uint8_t> key, std::span<const uint8_t> iv, std::span<const uint8_t> ciphertext,
    SecretBytes& out, TimeGuard& guard)
{
    return aesCfb8Transform(key, iv, ciphertext, false, out, guard);
}

bool aesCtrTransform(std::span<const uint8_t> key, std::span<const uint8_t> counter_block, uint8_t counter_bits,
    std::span<const uint8_t> input, SecretBytes& out, TimeGuard& guard)
{
    if (!isValidAesKeyLength(key.size()) || counter_block.size() != 16 || !counter_bits || counter_bits > 128)
        return false;
    const size_t blocks = input.empty() ? 0 : ((input.size() - 1) / 16) + 1;
    if (counter_bits < sizeof(size_t) * 8 && blocks > (static_cast<size_t>(1) << counter_bits))
        return false;

    // A 128-bit counter is the whole block, which EVP's CTR mode increments.
    if (counter_bits == 128)
        return aesCtrTransformWholeBlock(key, counter_block, input, out, guard);
    return aesCtrTransformPartialBlock(key, counter_block, counter_bits, input, out, guard);
}

bool aesKwWrap(std::span<const uint8_t> key, std::span<const uint8_t> plaintext, SecretBytes& out)
{
    if (!isValidAesKeyLength(key.size()) || plaintext.size() < 16 || (plaintext.size() % 8)
        || plaintext.size() > static_cast<size_t>(std::numeric_limits<int>::max() - 8))
        return false;
    if (!out.tryGrow(plaintext.size() + 8))
        return false;

    AES_KEY aes_key;
    if (AES_set_encrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) < 0) {
        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        return clearAndFail(out);
    }
    int written = AES_wrap_key(&aes_key, nullptr, out.mutableSpan().data(), plaintext.data(), plaintext.size());
    OPENSSL_cleanse(&aes_key, sizeof(aes_key));
    if (written < 0 || static_cast<size_t>(written) != out.size())
        return clearAndFail(out);
    return true;
}

bool aesKwUnwrap(std::span<const uint8_t> key, std::span<const uint8_t> ciphertext, SecretBytes& out)
{
    if (!isValidAesKeyLength(key.size()) || ciphertext.size() < 24 || (ciphertext.size() % 8)
        || ciphertext.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
        return false;
    if (!out.tryGrow(ciphertext.size() - 8))
        return false;

    AES_KEY aes_key;
    if (AES_set_decrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) < 0) {
        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        return clearAndFail(out);
    }
    int written = AES_unwrap_key(&aes_key, nullptr, out.mutableSpan().data(), ciphertext.data(), ciphertext.size());
    OPENSSL_cleanse(&aes_key, sizeof(aes_key));
    if (written < 0 || static_cast<size_t>(written) != out.size())
        return clearAndFail(out);
    return true;
}

}
