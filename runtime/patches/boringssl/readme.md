# BoringSSL Patches

These patches apply to the BoringSSL snapshot pinned in
`runtime/deps/boringssl.version`.

## 0001-boringssl-expose-sha3-evp-digests.patch

Expose SHA3 as `EVP_MD` digests using BoringSSL's existing Keccak
implementation. This follows Bun's `oven-sh/boringssl` fork strategy and keeps
WebCrypto SHA3 behavior available to EVP-backed paths such as RSA, PBKDF2, and
HKDF. Digest, HMAC, and ECDSA hashing still use Collo's local SHA3 helper.
