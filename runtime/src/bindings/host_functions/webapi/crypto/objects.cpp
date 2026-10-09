// Cell implementations for `Crypto`, `SubtleCrypto` and `CryptoKey`, the CryptoKey getters, and the interface
// constructors that refuse every call. Runs on the VM thread. Destructors zero the secret bytes a cell holds, the
// entropy cache included, and free the asymmetric key it owns.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/normalize.h"

#include <JavaScriptCore/JSCInlines.h>
#include <wtf/text/WTFString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <openssl/rand.h>
#include <wtf/StdLibExtras.h>

#include <algorithm>
#include <cstring>

namespace Collo::HostFunctions::WebCrypto {
using namespace JSC;
using WTF::String;
namespace {

    bool fillCryptoRandom(std::span<uint8_t> bytes)
    {
        return bytes.empty() || RAND_bytes(bytes.data(), bytes.size()) == 1;
    }

}

JSC::Structure* JSColloCrypto::createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

JSColloCrypto* JSColloCrypto::create(JSC::VM& vm, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloCrypto>(vm)) JSColloCrypto(vm, structure);
    object->finishCreation(vm);
    return object;
}

void JSColloCrypto::destroy(JSC::JSCell* cell) { static_cast<JSColloCrypto*>(cell)->~JSColloCrypto(); }

bool JSColloCrypto::fillRandom(uint64_t process_id, std::span<uint8_t> bytes)
{
    if (bytes.empty())
        return true;

    // A different process id means nothing filled the cache yet, or this process was forked from the one that did.
    if (m_entropy_process_id != process_id) {
        WTF::secureZeroSpan(std::span<uint8_t> {
            m_entropy_cache.data(),
            m_entropy_cache.size(),
        });
        m_entropy_offset = m_entropy_cache.size();
        m_entropy_process_id = process_id;
    }

    if (bytes.size() > max_cache_served_bytes) {
        return fillCryptoRandom(bytes);
    }

    while (!bytes.empty()) {
        if (m_entropy_offset == m_entropy_cache.size()) {
            // The cache fills on first use, never at creation, because the object is created in the zygote and every
            // worker would inherit bytes drawn there.
            if (!fillCryptoRandom(m_entropy_cache))
                return false;
            m_entropy_offset = 0;
        }

        auto available = m_entropy_cache.size() - m_entropy_offset;
        auto count = std::min(available, bytes.size());
        std::memcpy(bytes.data(), m_entropy_cache.data() + m_entropy_offset, count);
        // Served bytes are zeroed in the cache, so a later disclosure of the cache cannot reveal what callers got.
        WTF::secureZeroSpan(std::span<uint8_t> {
            m_entropy_cache.data() + m_entropy_offset,
            count,
        });
        m_entropy_offset += count;
        bytes = bytes.subspan(count);
    }
    return true;
}

JSColloCrypto::JSColloCrypto(JSC::VM& vm, JSC::Structure* structure)
    : Base(vm, structure)
{
}

JSColloCrypto::~JSColloCrypto()
{
    WTF::secureZeroSpan(std::span<uint8_t> {
        m_entropy_cache.data(),
        m_entropy_cache.size(),
    });
}

void JSColloCrypto::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

JSC::Structure* JSColloSubtleCrypto::createStructure(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

JSColloSubtleCrypto* JSColloSubtleCrypto::create(JSC::VM& vm, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloSubtleCrypto>(vm)) JSColloSubtleCrypto(vm, structure);
    object->finishCreation(vm);
    return object;
}

void JSColloSubtleCrypto::destroy(JSC::JSCell* cell)
{
    static_cast<JSColloSubtleCrypto*>(cell)->~JSColloSubtleCrypto();
}

JSColloSubtleCrypto::JSColloSubtleCrypto(JSC::VM& vm, JSC::Structure* structure)
    : Base(vm, structure)
{
}

void JSColloSubtleCrypto::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

JSC::Structure* JSColloCryptoKey::createStructure(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

JSColloCryptoKey* JSColloCryptoKey::create(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    WebCryptoHash hash, WTF::Vector<uint8_t>&& material, bool extractable, uint8_t usages, size_t hmac_length_bits)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloCryptoKey>(vm))
        JSColloCryptoKey(vm, structure, algorithm, hash, WTF::move(material), extractable, usages, hmac_length_bits);
    object->finishCreation(vm);
    return object;
}

JSColloCryptoKey* JSColloCryptoKey::createRsa(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    WebCryptoHash hash, CryptoKeyType type, EVP_PKEY* pkey, size_t modulus_bits, WTF::Vector<uint8_t>&& public_exponent,
    bool extractable, uint8_t usages)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloCryptoKey>(vm)) JSColloCryptoKey(
        vm, structure, algorithm, hash, type, pkey, modulus_bits, WTF::move(public_exponent), extractable, usages);
    object->finishCreation(vm);
    return object;
}

JSColloCryptoKey* JSColloCryptoKey::createEc(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    CryptoKeyNamedCurve named_curve, CryptoKeyType type, EVP_PKEY* pkey, bool extractable, uint8_t usages)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloCryptoKey>(vm))
        JSColloCryptoKey(vm, structure, algorithm, WebCryptoHash::SHA256, type, named_curve, pkey, extractable, usages);
    object->finishCreation(vm);
    return object;
}

JSColloCryptoKey* JSColloCryptoKey::createOkp(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    CryptoKeyNamedCurve named_curve, CryptoKeyType type, EVP_PKEY* pkey, bool extractable, uint8_t usages)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloCryptoKey>(vm))
        JSColloCryptoKey(vm, structure, algorithm, WebCryptoHash::SHA256, type, named_curve, pkey, extractable, usages);
    object->finishCreation(vm);
    return object;
}

void JSColloCryptoKey::destroy(JSC::JSCell* cell) { static_cast<JSColloCryptoKey*>(cell)->~JSColloCryptoKey(); }

JSColloCryptoKey::JSColloCryptoKey(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    WebCryptoHash hash, WTF::Vector<uint8_t>&& material, bool extractable, uint8_t usages, size_t hmac_length_bits)
    : Base(vm, structure)
    , m_algorithm(algorithm)
    , m_type(CryptoKeyType::Secret)
    , m_hash(hash)
    , m_material(WTF::move(material))
    , m_hmac_length_bits(hmac_length_bits)
    , m_extractable(extractable)
    , m_usages(usages)
{
}

JSColloCryptoKey::JSColloCryptoKey(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    WebCryptoHash hash, CryptoKeyType type, EVP_PKEY* rsa_key, size_t modulus_bits,
    WTF::Vector<uint8_t>&& public_exponent, bool extractable, uint8_t usages)
    : Base(vm, structure)
    , m_algorithm(algorithm)
    , m_type(type)
    , m_hash(hash)
    , m_rsa_key(rsa_key)
    , m_rsa_modulus_bits(modulus_bits)
    , m_rsa_public_exponent(WTF::move(public_exponent))
    , m_extractable(extractable)
    , m_usages(usages)
{
}

JSColloCryptoKey::JSColloCryptoKey(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    WebCryptoHash hash, CryptoKeyType type, CryptoKeyNamedCurve named_curve, EVP_PKEY* pkey, bool extractable,
    uint8_t usages)
    : Base(vm, structure)
    , m_algorithm(algorithm)
    , m_type(type)
    , m_named_curve(named_curve)
    , m_hash(hash)
    , m_rsa_key(pkey)
    , m_extractable(extractable)
    , m_usages(usages)
{
}

JSColloCryptoKey::~JSColloCryptoKey()
{
    if (!m_material.isEmpty()) {
        WTF::secureZeroSpan(std::span<uint8_t> {
            m_material.mutableSpan().data(),
            m_material.size(),
        });
    }
    if (m_rsa_key)
        EVP_PKEY_free(m_rsa_key);
}

void JSColloCryptoKey::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

const JSC::ClassInfo JSColloCrypto::s_info
    = { "Crypto"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloCrypto) };

const JSC::ClassInfo JSColloSubtleCrypto::s_info
    = { "SubtleCrypto"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloSubtleCrypto) };

const JSC::ClassInfo JSColloCryptoKey::s_info
    = { "CryptoKey"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloCryptoKey) };

static JSC::JSValue createUint8ArrayCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, bytes.size());
    if (scope.exception())
        return {};
    if (!bytes.empty())
        std::memcpy(array->vector(), bytes.data(), bytes.size());
    return array;
}

static JSC::JSValue createCryptoKeyAlgorithm(
    JSC::JSGlobalObject* global_object, JSC::VM& vm, JSC::ThrowScope& scope, JSColloCryptoKey* key)
{
    if (key->algorithm() == CryptoKeyAlgorithm::Pbkdf2 || key->algorithm() == CryptoKeyAlgorithm::Hkdf) {
        auto* algorithm = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 1);
        algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s),
            JSC::jsString(vm, key->algorithm() == CryptoKeyAlgorithm::Pbkdf2 ? String("PBKDF2"_s) : String("HKDF"_s)));
        return algorithm;
    }

    if (isAesAlgorithm(key->algorithm())) {
        auto* algorithm = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 2);
        algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s),
            JSC::jsString(vm, String(aesAlgorithmName(key->algorithm()))));
        algorithm->putDirect(
            vm, JSC::Identifier::fromString(vm, "length"_s), JSC::jsNumber(key->material().size() * 8));
        return algorithm;
    }

    if (isRsaAlgorithm(key->algorithm())) {
        auto public_exponent = createUint8ArrayCopy(global_object, scope, key->rsaPublicExponent());
        if (scope.exception())
            return {};

        const bool has_hash = key->algorithm() != CryptoKeyAlgorithm::RsaEsPkcs1V15;
        auto* algorithm = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), has_hash ? 4 : 3);
        algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s),
            JSC::jsString(vm, String(rsaAlgorithmName(key->algorithm()))));
        algorithm->putDirect(
            vm, JSC::Identifier::fromString(vm, "modulusLength"_s), JSC::jsNumber(key->rsaModulusBits()));
        algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "publicExponent"_s), public_exponent);
        if (has_hash) {
            auto* hash = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 1);
            hash->putDirect(
                vm, JSC::Identifier::fromString(vm, "name"_s), JSC::jsString(vm, String(hashSpec(key->hash()).name)));
            algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "hash"_s), hash);
        }
        return algorithm;
    }

    if (isEcAlgorithm(key->algorithm())) {
        auto* algorithm = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 2);
        algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s),
            JSC::jsString(vm, String(ecAlgorithmName(key->algorithm()))));
        algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "namedCurve"_s),
            JSC::jsString(vm, String(namedCurveName(key->namedCurve()))));
        return algorithm;
    }

    if (isOkpAlgorithm(key->algorithm())) {
        auto* algorithm = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 1);
        algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s),
            JSC::jsString(vm, String(okpAlgorithmName(key->algorithm()))));
        return algorithm;
    }

    const auto& spec = hashSpec(key->hash());
    auto* hash = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 1);
    hash->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s), JSC::jsString(vm, String(spec.name)));

    auto* algorithm = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 3);
    algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s), JSC::jsString(vm, String("HMAC"_s)));
    algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "hash"_s), hash);
    algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "length"_s), JSC::jsNumber(key->hmacLengthBits()));
    return algorithm;
}

JSC_DEFINE_HOST_FUNCTION(cryptoConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "Crypto is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(cryptoConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "Crypto is not constructable"_s);
}

// FIXME: Each read builds a new object, so `key.algorithm !== key.algorithm`. The Web Cryptography API (CryptoKey
// interface members) returns one cached object per key for `algorithm`, and likewise for `usages`, which
// `cryptoKeyGetUsages` also rebuilds on every read.
JSC_DEFINE_HOST_FUNCTION(cryptoKeyGetAlgorithm, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->thisValue());
    if (!key)
        return JSC::throwVMTypeError(global_object, scope, "CryptoKey accessor called on incompatible receiver"_s);
    return JSC::JSValue::encode(createCryptoKeyAlgorithm(global_object, vm, scope, key));
}

JSC_DEFINE_HOST_FUNCTION(cryptoKeyGetExtractable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->thisValue());
    if (!key)
        return JSC::throwVMTypeError(global_object, scope, "CryptoKey accessor called on incompatible receiver"_s);
    return JSC::JSValue::encode(JSC::jsBoolean(key->extractable()));
}

JSC_DEFINE_HOST_FUNCTION(cryptoKeyGetType, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->thisValue());
    if (!key)
        return JSC::throwVMTypeError(global_object, scope, "CryptoKey accessor called on incompatible receiver"_s);
    switch (key->type()) {
    case CryptoKeyType::Secret:
        return JSC::JSValue::encode(JSC::jsString(vm, String("secret"_s)));
    case CryptoKeyType::Public:
        return JSC::JSValue::encode(JSC::jsString(vm, String("public"_s)));
    case CryptoKeyType::Private:
        return JSC::JSValue::encode(JSC::jsString(vm, String("private"_s)));
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSC_DEFINE_HOST_FUNCTION(cryptoKeyGetUsages, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->thisValue());
    if (!key)
        return JSC::throwVMTypeError(global_object, scope, "CryptoKey accessor called on incompatible receiver"_s);
    auto* usages = createUsagesArray(global_object, vm, key->usages());
    if (!usages)
        return JSC::JSValue::encode(JSC::JSValue());
    return JSC::JSValue::encode(usages);
}

JSC::JSFunction* createCryptoConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "Crypto"_s, cryptoConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, cryptoConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    return constructor;
}

JSC_DEFINE_HOST_FUNCTION(subtleCryptoConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "SubtleCrypto is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(subtleCryptoConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "SubtleCrypto is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(cryptoKeyConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "CryptoKey is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(cryptoKeyConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "CryptoKey is not constructable"_s);
}

JSC::JSFunction* createSubtleCryptoConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "SubtleCrypto"_s, subtleCryptoConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, subtleCryptoConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    return constructor;
}

JSC::JSFunction* createCryptoKeyConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "CryptoKey"_s, cryptoKeyConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, cryptoKeyConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    return constructor;
}

}
