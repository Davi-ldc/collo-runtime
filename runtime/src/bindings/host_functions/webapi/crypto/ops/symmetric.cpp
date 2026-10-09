// HMAC, AES and digests behind symmetric.h, which states the threading and output contract. GCM, CBC and CTR with a
// full 128-bit counter use BoringSSL's EVP ciphers. BoringSSL has no 8-bit CFB and no CTR with a narrower counter, so
// those, like key wrap, use the AES_KEY functions of aes.h. Every expanded AES_KEY and keystream buffer is cleansed
// before it leaves scope.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/ops/symmetric.h"

#include "host_functions/webapi/crypto/ops/sha3.h"

#include <openssl/aes.h>
#include <openssl/cipher.h>
#include <openssl/hmac.h>
#include <openssl/mem.h>
#include <wtf/Assertions.h>
#include <wtf/StdLibExtras.h>

#include <algorithm>
#include <cstring>
#include <limits>

namespace Collo::HostFunctions::WebCrypto {

static bool clearOutputAndFail(WTF::Vector<uint8_t>& out)
{
    secureZeroVector(out);
    out.clear();
    return false;
}

bool hmacSign(const HashSpec& hash, std::span<const uint8_t> key, std::span<const uint8_t> data,
    std::array<uint8_t, EVP_MAX_MD_SIZE>& out, unsigned& out_len)
{
    if (isSha3Hash(hash.id))
        return sha3HmacRaw(hash, key, data, out, out_len);

    auto* evp = hashEvp(hash);
    if (!evp)
        return false;
    auto* result = HMAC(evp, key.data(), key.size(), data.data(), data.size(), out.data(), &out_len);
    return result == out.data() && out_len == hash.digest_bytes;
}

static const EVP_CIPHER* aesCipherForKey(CryptoKeyAlgorithm algorithm, size_t key_bytes)
{
    switch (key_bytes) {
    case 16:
        switch (algorithm) {
        case CryptoKeyAlgorithm::AesCtr:
            return EVP_aes_128_ctr();
        case CryptoKeyAlgorithm::AesCbc:
            return EVP_aes_128_cbc();
        case CryptoKeyAlgorithm::AesGcm:
            return EVP_aes_128_gcm();
        case CryptoKeyAlgorithm::AesKw:
        case CryptoKeyAlgorithm::AesCfb:
        case CryptoKeyAlgorithm::Hmac:
        case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss:
        case CryptoKeyAlgorithm::RsaOaep:
        case CryptoKeyAlgorithm::Ecdsa:
        case CryptoKeyAlgorithm::Ecdh:
        case CryptoKeyAlgorithm::Ed25519:
        case CryptoKeyAlgorithm::X25519:
        case CryptoKeyAlgorithm::Pbkdf2:
        case CryptoKeyAlgorithm::Hkdf:
            return nullptr;
        }
        return nullptr;
    case 24:
        switch (algorithm) {
        case CryptoKeyAlgorithm::AesCtr:
            return EVP_aes_192_ctr();
        case CryptoKeyAlgorithm::AesCbc:
            return EVP_aes_192_cbc();
        case CryptoKeyAlgorithm::AesGcm:
            return EVP_aes_192_gcm();
        case CryptoKeyAlgorithm::AesKw:
        case CryptoKeyAlgorithm::AesCfb:
        case CryptoKeyAlgorithm::Hmac:
        case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss:
        case CryptoKeyAlgorithm::RsaOaep:
        case CryptoKeyAlgorithm::Ecdsa:
        case CryptoKeyAlgorithm::Ecdh:
        case CryptoKeyAlgorithm::Ed25519:
        case CryptoKeyAlgorithm::X25519:
        case CryptoKeyAlgorithm::Pbkdf2:
        case CryptoKeyAlgorithm::Hkdf:
            return nullptr;
        }
        return nullptr;
    case 32:
        switch (algorithm) {
        case CryptoKeyAlgorithm::AesCtr:
            return EVP_aes_256_ctr();
        case CryptoKeyAlgorithm::AesCbc:
            return EVP_aes_256_cbc();
        case CryptoKeyAlgorithm::AesGcm:
            return EVP_aes_256_gcm();
        case CryptoKeyAlgorithm::AesKw:
        case CryptoKeyAlgorithm::AesCfb:
        case CryptoKeyAlgorithm::Hmac:
        case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss:
        case CryptoKeyAlgorithm::RsaOaep:
        case CryptoKeyAlgorithm::Ecdsa:
        case CryptoKeyAlgorithm::Ecdh:
        case CryptoKeyAlgorithm::Ed25519:
        case CryptoKeyAlgorithm::X25519:
        case CryptoKeyAlgorithm::Pbkdf2:
        case CryptoKeyAlgorithm::Hkdf:
            return nullptr;
        }
        return nullptr;
    default:
        return nullptr;
    }
}

bool isValidAesKeyLength(size_t byte_length) { return byte_length == 16 || byte_length == 24 || byte_length == 32; }

// The tag lengths Web Crypto allows for AES-GCM (32, 64, 96, 104, 112, 120 and 128 bits), in bytes.
static bool isValidAesGcmTagBytes(size_t tag_bytes)
{
    switch (tag_bytes) {
    case 4:
    case 8:
    case 12:
    case 13:
    case 14:
    case 15:
    case 16:
        return true;
    default:
        return false;
    }
}

// The EVP update functions take an int length.
static bool isValidCipherInputBytes(size_t byte_length)
{
    return byte_length <= static_cast<size_t>(std::numeric_limits<int>::max());
}

static int cipherInputBytes(size_t byte_length)
{
    ASSERT(isValidCipherInputBytes(byte_length));
    return static_cast<int>(byte_length);
}

WTF::ASCIILiteral aesJwkAlgorithm(CryptoKeyAlgorithm algorithm, size_t byte_length)
{
    switch (byte_length) {
    case 16:
        switch (algorithm) {
        case CryptoKeyAlgorithm::AesCtr:
            return "A128CTR"_s;
        case CryptoKeyAlgorithm::AesCbc:
            return "A128CBC"_s;
        case CryptoKeyAlgorithm::AesCfb:
            return "A128CFB8"_s;
        case CryptoKeyAlgorithm::AesGcm:
            return "A128GCM"_s;
        case CryptoKeyAlgorithm::AesKw:
            return "A128KW"_s;
        case CryptoKeyAlgorithm::Hmac:
        case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss:
        case CryptoKeyAlgorithm::RsaOaep:
        case CryptoKeyAlgorithm::Ecdsa:
        case CryptoKeyAlgorithm::Ecdh:
        case CryptoKeyAlgorithm::Ed25519:
        case CryptoKeyAlgorithm::X25519:
        case CryptoKeyAlgorithm::Pbkdf2:
        case CryptoKeyAlgorithm::Hkdf:
            break;
        }
        break;
    case 24:
        switch (algorithm) {
        case CryptoKeyAlgorithm::AesCtr:
            return "A192CTR"_s;
        case CryptoKeyAlgorithm::AesCbc:
            return "A192CBC"_s;
        case CryptoKeyAlgorithm::AesCfb:
            return "A192CFB8"_s;
        case CryptoKeyAlgorithm::AesGcm:
            return "A192GCM"_s;
        case CryptoKeyAlgorithm::AesKw:
            return "A192KW"_s;
        case CryptoKeyAlgorithm::Hmac:
        case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss:
        case CryptoKeyAlgorithm::RsaOaep:
        case CryptoKeyAlgorithm::Ecdsa:
        case CryptoKeyAlgorithm::Ecdh:
        case CryptoKeyAlgorithm::Ed25519:
        case CryptoKeyAlgorithm::X25519:
        case CryptoKeyAlgorithm::Pbkdf2:
        case CryptoKeyAlgorithm::Hkdf:
            break;
        }
        break;
    case 32:
        switch (algorithm) {
        case CryptoKeyAlgorithm::AesCtr:
            return "A256CTR"_s;
        case CryptoKeyAlgorithm::AesCbc:
            return "A256CBC"_s;
        case CryptoKeyAlgorithm::AesCfb:
            return "A256CFB8"_s;
        case CryptoKeyAlgorithm::AesGcm:
            return "A256GCM"_s;
        case CryptoKeyAlgorithm::AesKw:
            return "A256KW"_s;
        case CryptoKeyAlgorithm::Hmac:
        case CryptoKeyAlgorithm::RsaEsPkcs1V15:
        case CryptoKeyAlgorithm::RsaSsaPkcs1V15:
        case CryptoKeyAlgorithm::RsaPss:
        case CryptoKeyAlgorithm::RsaOaep:
        case CryptoKeyAlgorithm::Ecdsa:
        case CryptoKeyAlgorithm::Ecdh:
        case CryptoKeyAlgorithm::Ed25519:
        case CryptoKeyAlgorithm::X25519:
        case CryptoKeyAlgorithm::Pbkdf2:
        case CryptoKeyAlgorithm::Hkdf:
            break;
        }
        break;
    default:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

bool aesGcmEncrypt(std::span<const uint8_t> key, const AesGcmParams& params, std::span<const uint8_t> plaintext,
    WTF::Vector<uint8_t>& out)
{
    const EVP_CIPHER* cipher = aesCipherForKey(CryptoKeyAlgorithm::AesGcm, key.size());
    if (!cipher)
        return false;
    auto iv = params.iv.span();
    auto additional_data = params.additional_data.span();
    if (iv.empty() || iv.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
        return false;
    if (!isValidAesGcmTagBytes(params.tag_bytes))
        return false;
    if (plaintext.size() > std::numeric_limits<size_t>::max() - params.tag_bytes)
        return false;
    if (!isValidCipherInputBytes(plaintext.size()) || !isValidCipherInputBytes(additional_data.size()))
        return false;

    if (!out.tryReserveInitialCapacity(plaintext.size() + params.tag_bytes))
        return false;
    out.grow(plaintext.size() + params.tag_bytes);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_EncryptInit_ex(ctx.get(), cipher, nullptr, nullptr, nullptr))
        return fail();
    if (!EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(iv.size()), nullptr))
        return fail();
    if (!EVP_EncryptInit_ex(ctx.get(), nullptr, nullptr, key.data(), iv.data()))
        return fail();
    if (!additional_data.empty()) {
        int unused = 0;
        if (EVP_EncryptUpdate(
                ctx.get(), nullptr, &unused, additional_data.data(), cipherInputBytes(additional_data.size()))
            != 1)
            return fail();
    }

    int written_int = 0;
    if (EVP_EncryptUpdate(
            ctx.get(), out.mutableSpan().data(), &written_int, plaintext.data(), cipherInputBytes(plaintext.size()))
        != 1)
        return fail();
    auto written = static_cast<size_t>(written_int);
    int final_written_int = 0;
    if (EVP_EncryptFinal_ex(ctx.get(), out.mutableSpan().data() + written, &final_written_int) != 1)
        return fail();
    written += static_cast<size_t>(final_written_int);
    if (written + params.tag_bytes != out.size())
        return fail();
    if (!EVP_CIPHER_CTX_ctrl(
            ctx.get(), EVP_CTRL_GCM_GET_TAG, static_cast<int>(params.tag_bytes), out.mutableSpan().data() + written))
        return fail();
    return true;
}

bool aesGcmDecrypt(std::span<const uint8_t> key, const AesGcmParams& params,
    std::span<const uint8_t> ciphertext_and_tag, WTF::Vector<uint8_t>& out)
{
    const EVP_CIPHER* cipher = aesCipherForKey(CryptoKeyAlgorithm::AesGcm, key.size());
    if (!cipher || ciphertext_and_tag.size() < params.tag_bytes)
        return false;
    auto iv = params.iv.span();
    auto additional_data = params.additional_data.span();
    if (iv.empty() || iv.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
        return false;
    if (!isValidAesGcmTagBytes(params.tag_bytes))
        return false;
    auto ciphertext_len = ciphertext_and_tag.size() - params.tag_bytes;
    if (!isValidCipherInputBytes(ciphertext_len) || !isValidCipherInputBytes(additional_data.size()))
        return false;

    auto ciphertext = ciphertext_and_tag.subspan(0, ciphertext_len);
    auto tag = ciphertext_and_tag.subspan(ciphertext_len, params.tag_bytes);

    if (!out.tryReserveInitialCapacity(ciphertext_len))
        return false;
    out.grow(ciphertext_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_DecryptInit_ex(ctx.get(), cipher, nullptr, nullptr, nullptr))
        return fail();
    if (!EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(iv.size()), nullptr))
        return fail();
    if (!EVP_DecryptInit_ex(ctx.get(), nullptr, nullptr, key.data(), iv.data()))
        return fail();
    // The expected tag goes in before any input. Some backends require it before EVP_DecryptUpdate, and BoringSSL
    // accepts it at any point before EVP_DecryptFinal_ex, which compares it and fails on a mismatch.
    if (!EVP_CIPHER_CTX_ctrl(
            ctx.get(), EVP_CTRL_GCM_SET_TAG, static_cast<int>(params.tag_bytes), const_cast<uint8_t*>(tag.data())))
        return fail();
    if (!additional_data.empty()) {
        int unused = 0;
        if (EVP_DecryptUpdate(
                ctx.get(), nullptr, &unused, additional_data.data(), cipherInputBytes(additional_data.size()))
            != 1)
            return fail();
    }

    int written_int = 0;
    if (EVP_DecryptUpdate(
            ctx.get(), out.mutableSpan().data(), &written_int, ciphertext.data(), cipherInputBytes(ciphertext_len))
        != 1)
        return fail();
    auto written = static_cast<size_t>(written_int);
    int final_written_int = 0;
    if (EVP_DecryptFinal_ex(ctx.get(), out.mutableSpan().data() + written, &final_written_int) != 1)
        return fail();
    out.shrink(written + static_cast<size_t>(final_written_int));
    return true;
}

bool aesCbcEncrypt(std::span<const uint8_t> key, const AesCbcParams& params, std::span<const uint8_t> plaintext,
    WTF::Vector<uint8_t>& out)
{
    const EVP_CIPHER* cipher = aesCipherForKey(CryptoKeyAlgorithm::AesCbc, key.size());
    auto iv = params.iv.span();
    if (!cipher || iv.size() != 16 || plaintext.size() > std::numeric_limits<size_t>::max() - 16)
        return false;
    if (!isValidCipherInputBytes(plaintext.size()))
        return false;

    if (!out.tryReserveInitialCapacity(plaintext.size() + 16))
        return false;
    out.grow(plaintext.size() + 16);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_EncryptInit_ex(ctx.get(), cipher, nullptr, key.data(), iv.data()))
        return fail();

    int written_int = 0;
    if (EVP_EncryptUpdate(
            ctx.get(), out.mutableSpan().data(), &written_int, plaintext.data(), cipherInputBytes(plaintext.size()))
        != 1)
        return fail();
    auto written = static_cast<size_t>(written_int);
    int final_written_int = 0;
    if (EVP_EncryptFinal_ex(ctx.get(), out.mutableSpan().data() + written, &final_written_int) != 1)
        return fail();

    out.shrink(written + static_cast<size_t>(final_written_int));
    return true;
}

bool aesCbcDecrypt(std::span<const uint8_t> key, const AesCbcParams& params, std::span<const uint8_t> ciphertext,
    WTF::Vector<uint8_t>& out)
{
    const EVP_CIPHER* cipher = aesCipherForKey(CryptoKeyAlgorithm::AesCbc, key.size());
    auto iv = params.iv.span();
    if (!cipher || iv.size() != 16 || ciphertext.empty() || (ciphertext.size() % 16))
        return false;
    if (!isValidCipherInputBytes(ciphertext.size()))
        return false;

    if (!out.tryReserveInitialCapacity(ciphertext.size()))
        return false;
    out.grow(ciphertext.size());
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_DecryptInit_ex(ctx.get(), cipher, nullptr, key.data(), iv.data()))
        return fail();

    int written_int = 0;
    if (EVP_DecryptUpdate(
            ctx.get(), out.mutableSpan().data(), &written_int, ciphertext.data(), cipherInputBytes(ciphertext.size()))
        != 1)
        return fail();
    auto written = static_cast<size_t>(written_int);
    int final_written_int = 0;
    if (EVP_DecryptFinal_ex(ctx.get(), out.mutableSpan().data() + written, &final_written_int) != 1)
        return fail();

    out.shrink(written + static_cast<size_t>(final_written_int));
    return true;
}

// CFB with 8-bit feedback: each output byte is the input byte XOR the first byte of AES applied to the last 16
// feedback bytes, and the ciphertext byte joins the feedback. shift_register holds that window at offset `shift`;
// each new byte lands at 16 + shift, and after 16 of them the newer half moves to the front.
static bool aesCfb8Transform(std::span<const uint8_t> key, const AesCfbParams& params, std::span<const uint8_t> input,
    bool encrypt, WTF::Vector<uint8_t>& out)
{
    auto iv = params.iv.span();
    if (!isValidAesKeyLength(key.size()) || iv.size() != 16)
        return false;

    if (!out.tryReserveInitialCapacity(input.size()))
        return false;
    out.grow(input.size());
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    AES_KEY aes_key;
    if (AES_set_encrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) < 0) {
        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        return fail();
    }

    std::array<uint8_t, 32> shift_register {};
    std::copy(iv.begin(), iv.end(), shift_register.begin());
    std::array<uint8_t, 16> encrypted_block {};
    size_t shift = 0;

    for (size_t index = 0; index < input.size(); ++index) {
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
    return true;
}

bool aesCfb8Encrypt(std::span<const uint8_t> key, const AesCfbParams& params, std::span<const uint8_t> plaintext,
    WTF::Vector<uint8_t>& out)
{
    return aesCfb8Transform(key, params, plaintext, true, out);
}

bool aesCfb8Decrypt(std::span<const uint8_t> key, const AesCfbParams& params, std::span<const uint8_t> ciphertext,
    WTF::Vector<uint8_t>& out)
{
    return aesCfb8Transform(key, params, ciphertext, false, out);
}

// Adds one to the rightmost `length` bits of the counter block, modulo 2^length, and leaves the other bits alone.
static void incrementAesCtrCounter(std::array<uint8_t, 16>& counter, uint8_t length)
{
    size_t bits_remaining = length;
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

static bool aesCtrTransformFullCounter(std::span<const uint8_t> key, std::span<const uint8_t> counter,
    std::span<const uint8_t> input, WTF::Vector<uint8_t>& out)
{
    const EVP_CIPHER* cipher = aesCipherForKey(CryptoKeyAlgorithm::AesCtr, key.size());
    if (!cipher || counter.size() != 16)
        return false;
    if (input.empty())
        return true;
    if (!isValidCipherInputBytes(input.size()))
        return false;

    if (!out.tryReserveInitialCapacity(input.size()))
        return false;
    out.grow(input.size());

    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    bssl::ScopedEVP_CIPHER_CTX ctx;
    if (!EVP_EncryptInit_ex(ctx.get(), cipher, nullptr, key.data(), counter.data()))
        return fail();

    int written_int = 0;
    if (EVP_CipherUpdate(
            ctx.get(), out.mutableSpan().data(), &written_int, input.data(), cipherInputBytes(input.size()))
        != 1)
        return fail();
    auto written = static_cast<size_t>(written_int);

    int final_written_int = 0;
    if (EVP_EncryptFinal_ex(ctx.get(), out.mutableSpan().data() + written, &final_written_int) != 1)
        return fail();

    written += static_cast<size_t>(final_written_int);
    if (written != out.size())
        return fail();
    return true;
}

bool aesCtrTransform(
    std::span<const uint8_t> key, const AesCtrParams& params, std::span<const uint8_t> input, WTF::Vector<uint8_t>& out)
{
    auto counter_span = params.counter.span();
    if (!isValidAesKeyLength(key.size()) || counter_span.size() != 16 || !params.length || params.length > 128)
        return false;

    auto blocks = input.empty() ? 0 : ((input.size() - 1) / 16) + 1;
    if (params.length < sizeof(size_t) * 8 && blocks > (static_cast<size_t>(1) << params.length))
        return false;

    // A 128-bit counter is the whole block, which EVP's CTR mode increments.
    if (params.length == 128)
        return aesCtrTransformFullCounter(key, counter_span, input, out);

    if (!out.tryReserveInitialCapacity(input.size()))
        return false;
    out.grow(input.size());
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    AES_KEY aes_key;
    if (AES_set_encrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) < 0) {
        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        return fail();
    }

    std::array<uint8_t, 16> counter;
    std::copy(counter_span.begin(), counter_span.end(), counter.begin());
    std::array<uint8_t, 16> stream_block;

    for (size_t offset = 0; offset < input.size(); offset += 16) {
        AES_encrypt(counter.data(), stream_block.data(), &aes_key);
        auto chunk = std::min<size_t>(16, input.size() - offset);
        for (size_t index = 0; index < chunk; ++index)
            out.mutableSpan()[offset + index] = static_cast<uint8_t>(input[offset + index] ^ stream_block[index]);
        incrementAesCtrCounter(counter, params.length);
    }

    OPENSSL_cleanse(&aes_key, sizeof(aes_key));
    WTF::secureZeroSpan(std::span<uint8_t> { stream_block.data(), stream_block.size() });
    return true;
}

bool aesKwWrap(std::span<const uint8_t> key, std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out)
{
    if (!isValidAesKeyLength(key.size()) || plaintext.empty() || (plaintext.size() % 8)
        || plaintext.size() > static_cast<size_t>(std::numeric_limits<int>::max() - 8))
        return false;

    if (!out.tryReserveInitialCapacity(plaintext.size() + 8))
        return false;
    out.grow(plaintext.size() + 8);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    AES_KEY aes_key;
    if (AES_set_encrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) < 0) {
        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        return fail();
    }
    int written = AES_wrap_key(&aes_key, nullptr, out.mutableSpan().data(), plaintext.data(), plaintext.size());
    OPENSSL_cleanse(&aes_key, sizeof(aes_key));
    if (written < 0 || static_cast<size_t>(written) != out.size()) {
        return fail();
    }
    return true;
}

bool aesKwUnwrap(std::span<const uint8_t> key, std::span<const uint8_t> ciphertext, WTF::Vector<uint8_t>& out)
{
    if (!isValidAesKeyLength(key.size()) || ciphertext.size() < 16 || (ciphertext.size() % 8)
        || ciphertext.size() > static_cast<size_t>(std::numeric_limits<int>::max()))
        return false;

    if (!out.tryReserveInitialCapacity(ciphertext.size() - 8))
        return false;
    out.grow(ciphertext.size() - 8);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };

    AES_KEY aes_key;
    if (AES_set_decrypt_key(key.data(), static_cast<unsigned>(key.size() * 8), &aes_key) < 0) {
        OPENSSL_cleanse(&aes_key, sizeof(aes_key));
        return fail();
    }
    int written = AES_unwrap_key(&aes_key, nullptr, out.mutableSpan().data(), ciphertext.data(), ciphertext.size());
    OPENSSL_cleanse(&aes_key, sizeof(aes_key));
    if (written < 0 || static_cast<size_t>(written) != out.size()) {
        return fail();
    }
    return true;
}

bool digestBytes(const HashSpec& hash, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out)
{
    if (isSha3Hash(hash.id))
        return sha3DigestBytes(hash, data, out);

    auto* evp = hashEvp(hash);
    if (!evp)
        return false;
    std::array<uint8_t, EVP_MAX_MD_SIZE> digest;
    unsigned digest_len = 0;
    if (EVP_Digest(data.data(), data.size(), digest.data(), &digest_len, evp, nullptr) != 1
        || digest_len != hash.digest_bytes)
        return false;
    if (!out.tryReserveInitialCapacity(digest_len))
        return false;
    out.append(std::span<const uint8_t> { digest.data(), digest_len });
    return true;
}

} // namespace Collo::HostFunctions::WebCrypto
