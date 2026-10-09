// The JSC cells behind the Web Cryptography API objects: `Crypto`, which keeps an entropy cache, the stateless
// `SubtleCrypto`, and `CryptoKey`. The cells are created and used on the VM thread and destroyed when the collector
// sweeps them. A CryptoKey never changes after creation: a secret key keeps its bytes in a vector the destructor
// zeroes, and an asymmetric key owns an `EVP_PKEY` that crypto jobs read concurrently from pool threads.

#pragma once

#include "host_functions/webapi/crypto/types.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/Structure.h>
#include <openssl/evp.h>
#include <wtf/Vector.h>

#include <array>
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

    // Fills the span with random bytes from BoringSSL's RAND_bytes and returns false when it fails. A request of at
    // most `max_cache_served_bytes` is served from a cache refilled `entropy_cache_bytes` at a time; a larger one reads
    // RAND_bytes directly. `process_id` must be the VM's current process id (`ColloVm::process_id_at_creation`, which
    // `collo_vm_post_fork_child` updates). The Crypto object is created in the zygote, so a worker inherits its cache;
    // when the id differs from the one that filled the cache, the cache is zeroed before anything is served.
    bool fillRandom(uint64_t process_id, std::span<uint8_t>);

private:
    JSColloCrypto(JSC::VM&, JSC::Structure*);
    ~JSColloCrypto();

    void finishCreation(JSC::VM&);

    static constexpr size_t entropy_cache_bytes = 4096;
    static constexpr size_t max_cache_served_bytes = entropy_cache_bytes / 8;

    std::array<uint8_t, entropy_cache_bytes> m_entropy_cache {};
    size_t m_entropy_offset { entropy_cache_bytes };
    uint64_t m_entropy_process_id { 0 };
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

class JSColloCryptoKey final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    // The factories never return null: `allocateCell` crashes when allocation fails. `create` makes a secret key
    // from `material`. `createRsa`, `createEc` and `createOkp` take ownership of the `EVP_PKEY`, which the cell frees
    // when it is destroyed. Callers go through the validating factories in `keys.h`.
    static JSColloCryptoKey* create(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, WebCryptoHash,
        WTF::Vector<uint8_t>&& material, bool extractable, uint8_t usages, size_t hmac_length_bits = 0);
    static JSColloCryptoKey* createRsa(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, WebCryptoHash, CryptoKeyType,
        EVP_PKEY*, size_t modulus_bits, WTF::Vector<uint8_t>&& public_exponent, bool extractable, uint8_t usages);
    static JSColloCryptoKey* createEc(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, CryptoKeyNamedCurve, CryptoKeyType,
        EVP_PKEY*, bool extractable, uint8_t usages);
    static JSColloCryptoKey* createOkp(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, CryptoKeyNamedCurve,
        CryptoKeyType, EVP_PKEY*, bool extractable, uint8_t usages);
    static void destroy(JSC::JSCell*);

    DECLARE_INFO;

    CryptoKeyAlgorithm algorithm() const { return m_algorithm; }
    CryptoKeyType type() const { return m_type; }
    CryptoKeyNamedCurve namedCurve() const { return m_named_curve; }
    WebCryptoHash hash() const { return m_hash; }
    // The secret bytes of an AES, HMAC, PBKDF2 or HKDF key; empty for an asymmetric key.
    std::span<const uint8_t> material() const { return m_material.span(); }
    // Both return `m_rsa_key`, the key of any asymmetric algorithm.
    EVP_PKEY* rsaKey() const { return m_rsa_key; }
    EVP_PKEY* asymmetricKey() const { return m_rsa_key; }
    size_t rsaModulusBits() const { return m_rsa_modulus_bits; }
    std::span<const uint8_t> rsaPublicExponent() const { return m_rsa_public_exponent.span(); }
    bool extractable() const { return m_extractable; }
    uint8_t usages() const { return m_usages; }
    bool allows(CryptoKeyUsage usage) const { return m_usages & usage; }
    // An HMAC import may declare a `length` within (data bits - 8, data bits], and `key.algorithm.length` reports the
    // declared value; a key created without one reports the size of its bytes.
    size_t hmacLengthBits() const { return m_hmac_length_bits ? m_hmac_length_bits : m_material.size() * 8; }

private:
    JSColloCryptoKey(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, WebCryptoHash, WTF::Vector<uint8_t>&& material,
        bool extractable, uint8_t usages, size_t hmac_length_bits);
    JSColloCryptoKey(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, WebCryptoHash, CryptoKeyType, EVP_PKEY*,
        size_t modulus_bits, WTF::Vector<uint8_t>&& public_exponent, bool extractable, uint8_t usages);
    JSColloCryptoKey(JSC::VM&, JSC::Structure*, CryptoKeyAlgorithm, WebCryptoHash, CryptoKeyType, CryptoKeyNamedCurve,
        EVP_PKEY*, bool extractable, uint8_t usages);
    ~JSColloCryptoKey();

    void finishCreation(JSC::VM&);

    CryptoKeyAlgorithm m_algorithm { CryptoKeyAlgorithm::Hmac };
    CryptoKeyType m_type { CryptoKeyType::Secret };
    CryptoKeyNamedCurve m_named_curve { CryptoKeyNamedCurve::None };
    WebCryptoHash m_hash { WebCryptoHash::SHA256 };
    WTF::Vector<uint8_t> m_material;
    size_t m_hmac_length_bits { 0 };
    // Owned, and freed by the destructor. Despite the name it holds the key of every asymmetric algorithm: RSA, EC
    // and OKP. Crypto jobs share it with pool threads through `retainSharedPkey`, and BoringSSL allows concurrent use
    // of an `EVP_PKEY` only by non-mutating functions, so nothing may mutate it once the cell exists.
    EVP_PKEY* m_rsa_key { nullptr };
    size_t m_rsa_modulus_bits { 0 };
    WTF::Vector<uint8_t> m_rsa_public_exponent;
    bool m_extractable { false };
    uint8_t m_usages { 0 };
};

// Getters on `CryptoKey.prototype`; each throws a TypeError when the receiver is not a CryptoKey.
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetAlgorithm);
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetExtractable);
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetType);
JSC_DECLARE_HOST_FUNCTION(cryptoKeyGetUsages);

// The interface constructors. Calling or constructing any of them throws a TypeError.
JSC::JSFunction* createCryptoConstructor(JSC::JSGlobalObject*, JSC::VM&);
JSC::JSFunction* createSubtleCryptoConstructor(JSC::JSGlobalObject*, JSC::VM&);
JSC::JSFunction* createCryptoKeyConstructor(JSC::JSGlobalObject*, JSC::VM&);

}
