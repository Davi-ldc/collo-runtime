// The JSC cells behind the Web Cryptography API objects: `Crypto`, `SubtleCrypto` and `CryptoKey`. They are created and
// used on the VM thread and destroyed when the collector sweeps them. Crypto and SubtleCrypto hold no state. A
// CryptoKey never changes after creation: a secret key keeps its bytes in a `SecretBytes`, which zeroes them when the
// cell is destroyed, and an asymmetric key owns its `EVP_PKEY`, which every operation only reads.

#pragma once

#include "host_functions/webapi/crypto/types.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/Structure.h>
#include <openssl/evp.h>
#include <wtf/Vector.h>

#include <cstdint>
#include <span>

namespace Collo::HostFunctions::WebCrypto {

class JSColloCrypto final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    static JSColloCrypto* create(JSC::VM&, JSC::Structure*);
    static void destroy(JSC::JSCell*);

    DECLARE_INFO;

private:
    JSColloCrypto(JSC::VM&, JSC::Structure*);
    ~JSColloCrypto() = default;

    void finishCreation(JSC::VM&);
};

class JSColloSubtleCrypto final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    static JSColloSubtleCrypto* create(JSC::VM&, JSC::Structure*);
    static void destroy(JSC::JSCell*);

    DECLARE_INFO;

private:
    JSColloSubtleCrypto(JSC::VM&, JSC::Structure*);
    ~JSColloSubtleCrypto() = default;

    void finishCreation(JSC::VM&);
};

// What an asymmetric CryptoKey holds. The RSA fields are empty for an EC or OKP key, and `named_curve` is None for an
// RSA key.
struct AsymmetricKeyParts {
    CryptoKeyAlgorithm algorithm { CryptoKeyAlgorithm::RsaPss };
    WebCryptoHash hash { WebCryptoHash::SHA256 };
    CryptoKeyType type { CryptoKeyType::Public };
    CryptoKeyNamedCurve named_curve { CryptoKeyNamedCurve::None };
    bssl::UniquePtr<EVP_PKEY> pkey;
    size_t rsa_modulus_bits { 0 };
    WTF::Vector<uint8_t> rsa_public_exponent;
    bool extractable { false };
    uint8_t usages { 0 };
};

class JSColloCryptoKey final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    // The factories never return null: `allocateCell` crashes when allocation fails. Callers go through the validating
    // factories in keys.h. `hmac_length_bits` is the `length` an HMAC import declared, or 0.
    static JSColloCryptoKey* createSecret(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, WebCryptoHash,
        SecretBytes&& material, bool extractable, uint8_t usages, size_t hmac_length_bits);
    static JSColloCryptoKey* createAsymmetric(JSC::VM&, JSC::Structure*, AsymmetricKeyParts&&);
    static void destroy(JSC::JSCell*);

    DECLARE_INFO;

    CryptoKeyAlgorithm algorithm() const { return m_algorithm; }
    CryptoKeyType type() const { return m_type; }
    CryptoKeyNamedCurve namedCurve() const { return m_named_curve; }
    WebCryptoHash hash() const { return m_hash; }
    // The secret bytes of an AES, HMAC, PBKDF2 or HKDF key; empty for an asymmetric key.
    std::span<const uint8_t> material() const { return m_material.span(); }
    // The key of an RSA, EC or OKP algorithm; null for a secret key.
    EVP_PKEY* pkey() const { return m_pkey.get(); }
    size_t rsaModulusBits() const { return m_rsa_modulus_bits; }
    std::span<const uint8_t> rsaPublicExponent() const { return m_rsa_public_exponent.span(); }
    bool extractable() const { return m_extractable; }
    uint8_t usages() const { return m_usages; }
    bool allows(CryptoKeyUsage usage) const { return m_usages & usage; }
    // An HMAC import may declare a `length` within (data bits - 8, data bits], and `key.algorithm.length` reports the
    // declared value; a key created without one reports the size of its bytes.
    size_t hmacLengthBits() const { return m_hmac_length_bits ? m_hmac_length_bits : m_material.size() * 8; }

private:
    JSColloCryptoKey(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, WebCryptoHash, SecretBytes&& material,
        bool extractable, uint8_t usages, size_t hmac_length_bits);
    JSColloCryptoKey(JSC::VM&, JSC::Structure*, AsymmetricKeyParts&&);
    ~JSColloCryptoKey() = default;

    void finishCreation(JSC::VM&);

    CryptoKeyAlgorithm m_algorithm { CryptoKeyAlgorithm::Hmac };
    CryptoKeyType m_type { CryptoKeyType::Secret };
    CryptoKeyNamedCurve m_named_curve { CryptoKeyNamedCurve::None };
    WebCryptoHash m_hash { WebCryptoHash::SHA256 };
    bool m_extractable { false };
    uint8_t m_usages { 0 };
    SecretBytes m_material;
    size_t m_hmac_length_bits { 0 };
    bssl::UniquePtr<EVP_PKEY> m_pkey;
    size_t m_rsa_modulus_bits { 0 };
    WTF::Vector<uint8_t> m_rsa_public_exponent;
};

// Getters on `CryptoKey.prototype`; each throws a TypeError when the receiver is not a CryptoKey.
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetAlgorithm);
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetExtractable);
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetType);
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetUsages);

// The constructor of the interface `name`, `Crypto`, `SubtleCrypto` or `CryptoKey`, which throws a TypeError on every
// call and construction.
JSC::JSFunction* createInterfaceConstructor(JSC::JSGlobalObject*, JSC::VM&, WTF::ASCIILiteral name);

}
