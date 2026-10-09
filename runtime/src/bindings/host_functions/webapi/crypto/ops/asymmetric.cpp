// RSA, ECDSA, Ed25519, ECDH and X25519 operations on BoringSSL keys, under the contract in asymmetric.h. RSA and
// ECDSA hash the message with digestBytes (symmetric.cpp), which covers SHA-3, and hand BoringSSL the digest. Every
// stack buffer that holds a shared secret is zeroed before it leaves scope.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/ops/asymmetric.h"

#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"

#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/ecdsa.h>
#include <openssl/evp.h>
#include <openssl/mem.h>
#include <openssl/rsa.h>
#include <wtf/StdLibExtras.h>

#include <array>
#include <cstring>
#include <limits>

namespace Collo::HostFunctions::WebCrypto {

static bool clearOutputAndFail(WTF::Vector<uint8_t>& out)
{
    secureZeroVector(out);
    out.clear();
    return false;
}

bool rsaSignDigestNative(EVP_PKEY* key, WebCryptoHash hash_id, std::span<const uint8_t> data, int padding,
    std::optional<uint32_t> salt_length, WTF::Vector<uint8_t>& out)
{
    const auto& hash = hashSpec(hash_id);
    auto* evp = hashEvp(hash);
    if (!evp)
        return false;
    WTF::Vector<uint8_t> digest;
    if (!digestBytes(hash, data, digest))
        return false;

    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_sign_init(ctx.get()) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_rsa_padding(ctx.get(), padding) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_signature_md(ctx.get(), evp) <= 0)
        return false;
    if (padding == RSA_PKCS1_PSS_PADDING) {
        if (!salt_length || *salt_length > static_cast<uint32_t>(std::numeric_limits<int>::max()))
            return false;
        if (EVP_PKEY_CTX_set_rsa_pss_saltlen(ctx.get(), static_cast<int>(*salt_length)) <= 0)
            return false;
        if (EVP_PKEY_CTX_set_rsa_mgf1_md(ctx.get(), evp) <= 0)
            return false;
    }

    size_t signature_len = 0;
    if (EVP_PKEY_sign(ctx.get(), nullptr, &signature_len, digest.span().data(), digest.size()) <= 0)
        return false;
    if (!out.tryReserveInitialCapacity(signature_len))
        return false;
    out.grow(signature_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };
    if (EVP_PKEY_sign(ctx.get(), out.mutableSpan().data(), &signature_len, digest.span().data(), digest.size()) <= 0)
        return fail();
    out.shrink(signature_len);
    return true;
}

bool rsaVerifyDigestNative(EVP_PKEY* key, WebCryptoHash hash_id, std::span<const uint8_t> signature,
    std::span<const uint8_t> data, int padding, std::optional<uint32_t> salt_length, bool& out)
{
    const auto& hash = hashSpec(hash_id);
    auto* evp = hashEvp(hash);
    if (!evp)
        return false;
    WTF::Vector<uint8_t> digest;
    if (!digestBytes(hash, data, digest))
        return false;

    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_verify_init(ctx.get()) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_rsa_padding(ctx.get(), padding) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_signature_md(ctx.get(), evp) <= 0)
        return false;
    if (padding == RSA_PKCS1_PSS_PADDING) {
        if (!salt_length || *salt_length > static_cast<uint32_t>(std::numeric_limits<int>::max()))
            return false;
        if (EVP_PKEY_CTX_set_rsa_pss_saltlen(ctx.get(), static_cast<int>(*salt_length)) <= 0)
            return false;
        if (EVP_PKEY_CTX_set_rsa_mgf1_md(ctx.get(), evp) <= 0)
            return false;
    }

    int result = EVP_PKEY_verify(ctx.get(), signature.data(), signature.size(), digest.span().data(), digest.size());
    out = result == 1;
    return result >= 0;
}

static bool configureRsaOaep(EVP_PKEY_CTX* ctx, const HashSpec& hash, std::span<const uint8_t> label_bytes)
{
    auto* evp = hashEvp(hash);
    if (!evp)
        return false;
    if (EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_rsa_oaep_md(ctx, evp) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, evp) <= 0)
        return false;
    if (!label_bytes.empty()) {
        auto* label = static_cast<uint8_t*>(OPENSSL_malloc(label_bytes.size()));
        if (!label)
            return false;
        std::memcpy(label, label_bytes.data(), label_bytes.size());
        // EVP_PKEY_CTX_set0_rsa_oaep_label takes ownership of `label` only when it succeeds, so the failure path
        // frees it here, once.
        if (EVP_PKEY_CTX_set0_rsa_oaep_label(ctx, label, label_bytes.size()) <= 0) {
            OPENSSL_free(label);
            return false;
        }
    }
    return true;
}

bool rsaOaepEncryptNative(EVP_PKEY* key, WebCryptoHash hash, std::span<const uint8_t> label,
    std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_encrypt_init(ctx.get()) <= 0)
        return false;
    if (!configureRsaOaep(ctx.get(), hashSpec(hash), label))
        return false;

    size_t ciphertext_len = 0;
    if (EVP_PKEY_encrypt(ctx.get(), nullptr, &ciphertext_len, plaintext.data(), plaintext.size()) <= 0)
        return false;
    if (!out.tryReserveInitialCapacity(ciphertext_len))
        return false;
    out.grow(ciphertext_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };
    if (EVP_PKEY_encrypt(ctx.get(), out.mutableSpan().data(), &ciphertext_len, plaintext.data(), plaintext.size()) <= 0)
        return fail();
    out.shrink(ciphertext_len);
    return true;
}

bool rsaOaepDecryptNative(EVP_PKEY* key, WebCryptoHash hash, std::span<const uint8_t> label,
    std::span<const uint8_t> ciphertext, WTF::Vector<uint8_t>& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_decrypt_init(ctx.get()) <= 0)
        return false;
    if (!configureRsaOaep(ctx.get(), hashSpec(hash), label))
        return false;

    size_t plaintext_len = 0;
    if (EVP_PKEY_decrypt(ctx.get(), nullptr, &plaintext_len, ciphertext.data(), ciphertext.size()) <= 0)
        return false;
    if (!out.tryReserveInitialCapacity(plaintext_len))
        return false;
    out.grow(plaintext_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };
    if (EVP_PKEY_decrypt(ctx.get(), out.mutableSpan().data(), &plaintext_len, ciphertext.data(), ciphertext.size())
        <= 0)
        return fail();
    out.shrink(plaintext_len);
    return true;
}

bool rsaPkcs1EncryptNative(EVP_PKEY* key, std::span<const uint8_t> plaintext, WTF::Vector<uint8_t>& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_encrypt_init(ctx.get()) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_rsa_padding(ctx.get(), RSA_PKCS1_PADDING) <= 0)
        return false;

    size_t ciphertext_len = 0;
    if (EVP_PKEY_encrypt(ctx.get(), nullptr, &ciphertext_len, plaintext.data(), plaintext.size()) <= 0)
        return false;
    if (!out.tryReserveInitialCapacity(ciphertext_len))
        return false;
    out.grow(ciphertext_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };
    if (EVP_PKEY_encrypt(ctx.get(), out.mutableSpan().data(), &ciphertext_len, plaintext.data(), plaintext.size()) <= 0)
        return fail();
    out.shrink(ciphertext_len);
    return true;
}

bool rsaPkcs1DecryptNative(EVP_PKEY* key, std::span<const uint8_t> ciphertext, WTF::Vector<uint8_t>& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_decrypt_init(ctx.get()) <= 0)
        return false;
    if (EVP_PKEY_CTX_set_rsa_padding(ctx.get(), RSA_PKCS1_PADDING) <= 0)
        return false;

    size_t plaintext_len = 0;
    if (EVP_PKEY_decrypt(ctx.get(), nullptr, &plaintext_len, ciphertext.data(), ciphertext.size()) <= 0)
        return false;
    if (!out.tryReserveInitialCapacity(plaintext_len))
        return false;
    out.grow(plaintext_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };
    if (EVP_PKEY_decrypt(ctx.get(), out.mutableSpan().data(), &plaintext_len, ciphertext.data(), ciphertext.size())
        <= 0)
        return fail();
    out.shrink(plaintext_len);
    return true;
}

// A Web Crypto ECDSA signature is r followed by s (the IEEE P1363 encoding), each a big-endian integer left-padded to
// the byte length of the group order. Signing and verification build and read that form from an ECDSA_SIG.
static size_t ecdsaComponentBytes(const EC_KEY* ec)
{
    const EC_GROUP* group = EC_KEY_get0_group(ec);
    if (!group)
        return 0;
    int order_bits = EC_GROUP_order_bits(group);
    if (order_bits <= 0)
        return 0;
    return (static_cast<size_t>(order_bits) + 7) / 8;
}

bool ecdsaSignNative(EVP_PKEY* key, WebCryptoHash hash_id, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out)
{
    auto* ec = EVP_PKEY_get0_EC_KEY(key);
    if (!ec)
        return false;
    const size_t component_bytes = ecdsaComponentBytes(ec);
    if (!component_bytes)
        return false;
    WTF::Vector<uint8_t> digest;
    if (!digestBytes(hashSpec(hash_id), data, digest))
        return false;

    bssl::UniquePtr<ECDSA_SIG> sig(ECDSA_do_sign(digest.span().data(), digest.size(), ec));
    if (!sig)
        return false;
    const BIGNUM* r = nullptr;
    const BIGNUM* s = nullptr;
    ECDSA_SIG_get0(sig.get(), &r, &s);
    if (!r || !s)
        return false;

    const size_t signature_len = component_bytes * 2;
    if (!out.tryReserveInitialCapacity(signature_len))
        return false;
    out.grow(signature_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };
    if (BN_bn2bin_padded(out.mutableSpan().data(), component_bytes, r) != 1
        || BN_bn2bin_padded(out.mutableSpan().data() + component_bytes, component_bytes, s) != 1)
        return fail();
    return true;
}

bool ecdsaVerifyNative(
    EVP_PKEY* key, WebCryptoHash hash_id, std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out)
{
    out = false;
    auto* ec = EVP_PKEY_get0_EC_KEY(key);
    if (!ec)
        return false;
    const size_t component_bytes = ecdsaComponentBytes(ec);
    if (!component_bytes)
        return false;

    // Web Crypto ECDSA verification returns false, without failing, for a signature of any other length.
    if (signature.size() != component_bytes * 2) {
        out = false;
        return true;
    }

    WTF::Vector<uint8_t> digest;
    if (!digestBytes(hashSpec(hash_id), data, digest))
        return false;

    bssl::UniquePtr<BIGNUM> r(BN_bin2bn(signature.data(), component_bytes, nullptr));
    bssl::UniquePtr<BIGNUM> s(BN_bin2bn(signature.data() + component_bytes, component_bytes, nullptr));
    if (!r || !s)
        return false;
    bssl::UniquePtr<ECDSA_SIG> sig(ECDSA_SIG_new());
    if (!sig)
        return false;
    // ECDSA_SIG_set0 takes ownership of r and s on success.
    if (ECDSA_SIG_set0(sig.get(), r.get(), s.get()) != 1)
        return false;
    r.release();
    s.release();

    int result = ECDSA_do_verify(digest.span().data(), digest.size(), sig.get(), ec);
    out = result == 1;
    return result >= 0;
}

bool ed25519SignNative(EVP_PKEY* key, std::span<const uint8_t> data, WTF::Vector<uint8_t>& out)
{
    bssl::UniquePtr<EVP_MD_CTX> ctx(EVP_MD_CTX_new());
    if (!ctx || EVP_DigestSignInit(ctx.get(), nullptr, nullptr, nullptr, key) != 1)
        return false;

    size_t signature_len = 0;
    if (EVP_DigestSign(ctx.get(), nullptr, &signature_len, data.data(), data.size()) != 1 || !signature_len)
        return false;
    if (!out.tryReserveInitialCapacity(signature_len))
        return false;
    out.grow(signature_len);
    auto fail = [&]() -> bool { return clearOutputAndFail(out); };
    if (EVP_DigestSign(ctx.get(), out.mutableSpan().data(), &signature_len, data.data(), data.size()) != 1)
        return fail();
    out.shrink(signature_len);
    return true;
}

bool ed25519VerifyNative(EVP_PKEY* key, std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out)
{
    bssl::UniquePtr<EVP_MD_CTX> ctx(EVP_MD_CTX_new());
    if (!ctx || EVP_DigestVerifyInit(ctx.get(), nullptr, nullptr, nullptr, key) != 1)
        return false;
    int result = EVP_DigestVerify(ctx.get(), signature.data(), signature.size(), data.data(), data.size());
    out = result == 1;
    return result >= 0;
}

bool ecdhDeriveBitsNative(EVP_PKEY* private_key, EVP_PKEY* public_key, size_t length_bits, WTF::Vector<uint8_t>& out)
{
    // The ECDH shared secret is the x coordinate of the shared point, a big-endian integer left-padded to the byte
    // width of the curve's field. Some backends strip leading zero bytes from the derive output. BoringSSL writes the
    // full width, and the right-alignment below keeps the bits taken from the front correct either way.
    auto* ec = EVP_PKEY_get0_EC_KEY(private_key);
    const EC_GROUP* group = ec ? EC_KEY_get0_group(ec) : nullptr;
    if (!group)
        return false;
    const unsigned degree = EC_GROUP_get_degree(group);
    if (!degree)
        return false;
    const size_t field_bytes = (static_cast<size_t>(degree) + 7) / 8;

    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(private_key, nullptr));
    if (!ctx || EVP_PKEY_derive_init(ctx.get()) <= 0)
        return false;
    if (EVP_PKEY_derive_set_peer(ctx.get(), public_key) <= 0)
        return false;

    // 66 bytes is the field width of P-521, the largest curve in CryptoKeyNamedCurve.
    auto byte_length = (length_bits + 7) / 8;
    if (!byte_length || byte_length > field_bytes || field_bytes > 66)
        return false;

    // A derive that returns fewer bytes than the field width is right-aligned in the zeroed buffer, so the leading
    // bytes stay zero.
    std::array<uint8_t, 66> full {};
    size_t actual_len = field_bytes;
    if (EVP_PKEY_derive(ctx.get(), full.data(), &actual_len) <= 0 || !actual_len || actual_len > field_bytes) {
        WTF::secureZeroSpan(std::span<uint8_t> { full.data(), full.size() });
        return false;
    }
    if (actual_len < field_bytes) {
        const size_t shift = field_bytes - actual_len;
        std::memmove(full.data() + shift, full.data(), actual_len);
        std::memset(full.data(), 0, shift);
    }
    bool ok = out.tryAppend(std::span<const uint8_t> { full.data(), byte_length });
    WTF::secureZeroSpan(std::span<uint8_t> { full.data(), full.size() });
    return ok;
}

bool x25519DeriveBitsNative(EVP_PKEY* private_key, EVP_PKEY* public_key, size_t length_bits, WTF::Vector<uint8_t>& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(private_key, nullptr));
    if (!ctx || EVP_PKEY_derive_init(ctx.get()) <= 0)
        return false;
    if (EVP_PKEY_derive_set_peer(ctx.get(), public_key) <= 0)
        return false;

    size_t full_len = 0;
    if (EVP_PKEY_derive(ctx.get(), nullptr, &full_len) <= 0 || full_len != 32)
        return false;
    auto byte_length = (length_bits + 7) / 8;
    if (!byte_length || byte_length > full_len)
        return false;

    std::array<uint8_t, 32> full {};
    size_t actual_len = full.size();
    if (EVP_PKEY_derive(ctx.get(), full.data(), &actual_len) <= 0) {
        WTF::secureZeroSpan(std::span<uint8_t> { full.data(), full.size() });
        return false;
    }
    if (actual_len != full_len) {
        WTF::secureZeroSpan(std::span<uint8_t> { full.data(), full.size() });
        return false;
    }
    // An all-zero secret comes from a small-order peer point and fails the derive. BoringSSL's X25519 already rejects
    // it in constant time, so this early-exit loop only ever scans secrets that are not all zero.
    bool all_zero = true;
    for (uint8_t byte : full) {
        if (byte) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        WTF::secureZeroSpan(std::span<uint8_t> { full.data(), full.size() });
        return false;
    }
    bool ok = out.tryAppend(std::span<const uint8_t> { full.data(), byte_length });
    WTF::secureZeroSpan(std::span<uint8_t> { full.data(), full.size() });
    return ok;
}

} // namespace Collo::HostFunctions::WebCrypto
