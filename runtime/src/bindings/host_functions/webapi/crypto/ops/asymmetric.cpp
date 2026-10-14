// RSA, ECDSA, Ed25519, ECDH and X25519 operations on BoringSSL keys, under the contract in asymmetric.h. ECDSA signs
// and verifies in the P1363 encoding Web Crypto uses, which BoringSSL produces itself.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/ops/asymmetric.h"

#include <openssl/ec_key.h>
#include <openssl/ecdsa.h>
#include <openssl/evp.h>
#include <openssl/mem.h>
#include <openssl/rsa.h>

#include <cstring>
#include <limits>

namespace Collo::HostFunctions::WebCrypto {
namespace {

    // Prepares `ctx`, initialized for signing or verification, for RSA with `padding` over a digest of `hash`.
    bool configureRsaSignature(EVP_PKEY_CTX* ctx, const HashSpec& hash, int padding, uint32_t salt_length)
    {
        if (EVP_PKEY_CTX_set_rsa_padding(ctx, padding) <= 0)
            return false;
        if (EVP_PKEY_CTX_set_signature_md(ctx, hash.evp()) <= 0)
            return false;
        if (padding != RSA_PKCS1_PSS_PADDING)
            return true;
        if (salt_length > static_cast<uint32_t>(std::numeric_limits<int>::max()))
            return false;
        return EVP_PKEY_CTX_set_rsa_pss_saltlen(ctx, static_cast<int>(salt_length)) > 0
            && EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, hash.evp()) > 0;
    }

    bool configureRsaOaep(EVP_PKEY_CTX* ctx, const HashSpec& hash, std::span<const uint8_t> label_bytes)
    {
        if (EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_OAEP_PADDING) <= 0)
            return false;
        if (EVP_PKEY_CTX_set_rsa_oaep_md(ctx, hash.evp()) <= 0)
            return false;
        if (EVP_PKEY_CTX_set_rsa_mgf1_md(ctx, hash.evp()) <= 0)
            return false;
        if (label_bytes.empty())
            return true;
        auto* label = static_cast<uint8_t*>(OPENSSL_malloc(label_bytes.size()));
        if (!label)
            return false;
        std::memcpy(label, label_bytes.data(), label_bytes.size());
        // EVP_PKEY_CTX_set0_rsa_oaep_label takes ownership of `label` only when it succeeds, so the failure path frees
        // it here, once.
        if (EVP_PKEY_CTX_set0_rsa_oaep_label(ctx, label, label_bytes.size()) <= 0) {
            OPENSSL_free(label);
            return false;
        }
        return true;
    }

    // Runs EVP_PKEY_encrypt or EVP_PKEY_decrypt on a configured context: measures the output, then writes it.
    template <typename Transform>
    bool runPkeyTransform(EVP_PKEY_CTX* ctx, std::span<const uint8_t> input, SecretBytes& out, Transform transform)
    {
        size_t output_len = 0;
        if (transform(ctx, nullptr, &output_len, input.data(), input.size()) <= 0)
            return false;
        if (!out.tryGrow(output_len))
            return false;
        if (transform(ctx, out.data(), &output_len, input.data(), input.size()) <= 0)
            return clearAndFail(out);
        out.shrink(output_len);
        return true;
    }

} // namespace

bool rsaSignDigest(EVP_PKEY* key, const HashSpec& hash, std::span<const uint8_t> digest, int padding,
    uint32_t salt_length, SecretBytes& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_sign_init(ctx.get()) <= 0 || !configureRsaSignature(ctx.get(), hash, padding, salt_length))
        return false;
    size_t signature_len = 0;
    if (EVP_PKEY_sign(ctx.get(), nullptr, &signature_len, digest.data(), digest.size()) <= 0)
        return false;
    if (!out.tryGrow(signature_len))
        return false;
    if (EVP_PKEY_sign(ctx.get(), out.data(), &signature_len, digest.data(), digest.size()) <= 0)
        return clearAndFail(out);
    out.shrink(signature_len);
    return true;
}

bool rsaVerifyDigest(EVP_PKEY* key, const HashSpec& hash, std::span<const uint8_t> signature,
    std::span<const uint8_t> digest, int padding, uint32_t salt_length, bool& out)
{
    out = false;
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_verify_init(ctx.get()) <= 0 || !configureRsaSignature(ctx.get(), hash, padding, salt_length))
        return false;
    int result = EVP_PKEY_verify(ctx.get(), signature.data(), signature.size(), digest.data(), digest.size());
    out = result == 1;
    return result >= 0;
}

bool rsaOaepEncrypt(EVP_PKEY* key, const HashSpec& hash, std::span<const uint8_t> label,
    std::span<const uint8_t> plaintext, SecretBytes& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_encrypt_init(ctx.get()) <= 0 || !configureRsaOaep(ctx.get(), hash, label))
        return false;
    return runPkeyTransform(ctx.get(), plaintext, out, EVP_PKEY_encrypt);
}

bool rsaOaepDecrypt(EVP_PKEY* key, const HashSpec& hash, std::span<const uint8_t> label,
    std::span<const uint8_t> ciphertext, SecretBytes& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_decrypt_init(ctx.get()) <= 0 || !configureRsaOaep(ctx.get(), hash, label))
        return false;
    return runPkeyTransform(ctx.get(), ciphertext, out, EVP_PKEY_decrypt);
}

bool rsaPkcs1Encrypt(EVP_PKEY* key, std::span<const uint8_t> plaintext, SecretBytes& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_encrypt_init(ctx.get()) <= 0
        || EVP_PKEY_CTX_set_rsa_padding(ctx.get(), RSA_PKCS1_PADDING) <= 0)
        return false;
    return runPkeyTransform(ctx.get(), plaintext, out, EVP_PKEY_encrypt);
}

bool rsaPkcs1Decrypt(EVP_PKEY* key, std::span<const uint8_t> ciphertext, SecretBytes& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(key, nullptr));
    if (!ctx || EVP_PKEY_decrypt_init(ctx.get()) <= 0
        || EVP_PKEY_CTX_set_rsa_padding(ctx.get(), RSA_PKCS1_PADDING) <= 0)
        return false;
    return runPkeyTransform(ctx.get(), ciphertext, out, EVP_PKEY_decrypt);
}

bool ecdsaSignDigest(EVP_PKEY* key, std::span<const uint8_t> digest, SecretBytes& out)
{
    const EC_KEY* ec = EVP_PKEY_get0_EC_KEY(key);
    if (!ec)
        return false;
    const size_t signature_len = ECDSA_size_p1363(ec);
    if (!signature_len || !out.tryGrow(signature_len))
        return false;
    size_t written = 0;
    if (ECDSA_sign_p1363(digest.data(), digest.size(), out.data(), &written, signature_len, ec) != 1
        || written != signature_len)
        return clearAndFail(out);
    return true;
}

bool ecdsaVerifyDigest(EVP_PKEY* key, std::span<const uint8_t> signature, std::span<const uint8_t> digest, bool& out)
{
    out = false;
    const EC_KEY* ec = EVP_PKEY_get0_EC_KEY(key);
    if (!ec)
        return false;
    if (signature.size() != ECDSA_size_p1363(ec))
        return true;
    out = ECDSA_verify_p1363(digest.data(), digest.size(), signature.data(), signature.size(), ec) == 1;
    return true;
}

bool ed25519Sign(EVP_PKEY* key, std::span<const uint8_t> data, SecretBytes& out)
{
    bssl::UniquePtr<EVP_MD_CTX> ctx(EVP_MD_CTX_new());
    if (!ctx || EVP_DigestSignInit(ctx.get(), nullptr, nullptr, nullptr, key) != 1)
        return false;
    size_t signature_len = 0;
    if (EVP_DigestSign(ctx.get(), nullptr, &signature_len, data.data(), data.size()) != 1 || !signature_len)
        return false;
    if (!out.tryGrow(signature_len))
        return false;
    if (EVP_DigestSign(ctx.get(), out.data(), &signature_len, data.data(), data.size()) != 1)
        return clearAndFail(out);
    out.shrink(signature_len);
    return true;
}

bool ed25519Verify(EVP_PKEY* key, std::span<const uint8_t> signature, std::span<const uint8_t> data, bool& out)
{
    out = false;
    bssl::UniquePtr<EVP_MD_CTX> ctx(EVP_MD_CTX_new());
    if (!ctx || EVP_DigestVerifyInit(ctx.get(), nullptr, nullptr, nullptr, key) != 1)
        return false;
    int result = EVP_DigestVerify(ctx.get(), signature.data(), signature.size(), data.data(), data.size());
    out = result == 1;
    return result >= 0;
}

bool deriveSharedSecret(EVP_PKEY* private_key, EVP_PKEY* public_key, size_t length_bits, SecretBytes& out)
{
    bssl::UniquePtr<EVP_PKEY_CTX> ctx(EVP_PKEY_CTX_new(private_key, nullptr));
    if (!ctx || EVP_PKEY_derive_init(ctx.get()) <= 0 || EVP_PKEY_derive_set_peer(ctx.get(), public_key) <= 0)
        return false;
    // BoringSSL writes a secret of fixed width: an ECDH secret is the x coordinate left-padded to the field's byte
    // width, and an X25519 secret is 32 bytes.
    size_t secret_len = 0;
    if (EVP_PKEY_derive(ctx.get(), nullptr, &secret_len) <= 0 || !secret_len)
        return false;
    const size_t byte_length = (length_bits + 7) / 8;
    if (byte_length > secret_len || !out.tryGrow(secret_len))
        return false;
    size_t written = secret_len;
    if (EVP_PKEY_derive(ctx.get(), out.data(), &written) <= 0 || written != secret_len)
        return clearAndFail(out);
    out.shrink(byte_length);
    return true;
}

}
