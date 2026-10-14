# BoringSSL Patches

These patches apply to the BoringSSL snapshot pinned in `runtime/deps/boringssl.version`.

## 0001-boringssl-expose-sha3-evp-digests.patch

Expose SHA3 as `EVP_MD` digests using BoringSSL's existing Keccak implementation, following Bun's `oven-sh/boringssl` fork. The patch raises `EVP_MAX_MD_BLOCK_SIZE` to SHA3-224's 144-byte block and adds the SHA3 DigestInfo prefixes to RSA, so every WebCrypto use of a SHA3 hash runs through BoringSSL: digests, HMAC, RSA and ECDSA signatures, RSA-OAEP, PBKDF2 and HKDF.
