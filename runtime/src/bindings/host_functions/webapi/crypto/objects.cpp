// Cell implementations for `Crypto`, `SubtleCrypto` and `CryptoKey`, the CryptoKey getters, and the interface
// constructors that refuse every call. Runs on the VM thread. Destroying a CryptoKey zeroes its secret bytes through
// `SecretBytes` and frees the asymmetric key it owns.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/objects.h"

#include "host_functions/webapi/crypto/algorithms.h"
#include "host_functions/webapi/crypto/normalize.h"

#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <cstring>

namespace Collo::HostFunctions::WebCrypto {

using WTF::String;
// CREATE_METHOD_TABLE names JSC's JSCastingHelpers without qualification.
namespace JSCastingHelpers = JSC::JSCastingHelpers;

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

JSColloCrypto::JSColloCrypto(JSC::VM& vm, JSC::Structure* structure)
    : Base(vm, structure)
{
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

JSColloCryptoKey* JSColloCryptoKey::createSecret(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    WebCryptoHash hash, SecretBytes&& material, bool extractable, uint8_t usages, size_t hmac_length_bits)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloCryptoKey>(vm))
        JSColloCryptoKey(vm, structure, algorithm, hash, WTF::move(material), extractable, usages, hmac_length_bits);
    object->finishCreation(vm);
    return object;
}

JSColloCryptoKey* JSColloCryptoKey::createAsymmetric(JSC::VM& vm, JSC::Structure* structure, AsymmetricKeyParts&& parts)
{
    auto* object
        = new (NotNull, JSC::allocateCell<JSColloCryptoKey>(vm)) JSColloCryptoKey(vm, structure, WTF::move(parts));
    object->finishCreation(vm);
    return object;
}

void JSColloCryptoKey::destroy(JSC::JSCell* cell) { static_cast<JSColloCryptoKey*>(cell)->~JSColloCryptoKey(); }

JSColloCryptoKey::JSColloCryptoKey(JSC::VM& vm, JSC::Structure* structure, CryptoKeyAlgorithm algorithm,
    WebCryptoHash hash, SecretBytes&& material, bool extractable, uint8_t usages, size_t hmac_length_bits)
    : Base(vm, structure)
    , m_algorithm(algorithm)
    , m_type(CryptoKeyType::Secret)
    , m_hash(hash)
    , m_extractable(extractable)
    , m_usages(usages)
    , m_material(WTF::move(material))
    , m_hmac_length_bits(hmac_length_bits)
{
}

JSColloCryptoKey::JSColloCryptoKey(JSC::VM& vm, JSC::Structure* structure, AsymmetricKeyParts&& parts)
    : Base(vm, structure)
    , m_algorithm(parts.algorithm)
    , m_type(parts.type)
    , m_named_curve(parts.named_curve)
    , m_hash(parts.hash)
    , m_extractable(parts.extractable)
    , m_usages(parts.usages)
    , m_pkey(WTF::move(parts.pkey))
    , m_rsa_modulus_bits(parts.rsa_modulus_bits)
    , m_rsa_public_exponent(WTF::move(parts.rsa_public_exponent))
{
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

namespace {

    JSC::JSValue createUint8ArrayCopy(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
    {
        auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
        auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, bytes.size());
        RETURN_IF_EXCEPTION(scope, {});
        if (!bytes.empty())
            std::memcpy(array->vector(), bytes.data(), bytes.size());
        return array;
    }

    JSC::JSObject* createNamedObject(
        JSC::JSGlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name, unsigned inline_capacity)
    {
        auto* object = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), inline_capacity);
        object->putDirect(vm, JSC::Identifier::fromString(vm, "name"_s), JSC::jsString(vm, String(name)));
        return object;
    }

    // The KeyAlgorithm dictionary of `key`, with the members its family adds.
    JSC::JSValue createCryptoKeyAlgorithm(
        JSC::JSGlobalObject* global_object, JSC::VM& vm, JSC::ThrowScope& scope, JSColloCryptoKey* key)
    {
        const auto& spec = algorithmSpec(key->algorithm());
        switch (spec.family) {
        case AlgorithmFamily::Kdf:
        case AlgorithmFamily::Okp:
            return createNamedObject(global_object, vm, spec.name, 1);
        case AlgorithmFamily::Aes: {
            auto* algorithm = createNamedObject(global_object, vm, spec.name, 2);
            algorithm->putDirect(
                vm, JSC::Identifier::fromString(vm, "length"_s), JSC::jsNumber(key->material().size() * 8));
            return algorithm;
        }
        case AlgorithmFamily::Hmac: {
            auto* algorithm = createNamedObject(global_object, vm, spec.name, 3);
            algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "hash"_s),
                createNamedObject(global_object, vm, hashSpec(key->hash()).name, 1));
            algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "length"_s), JSC::jsNumber(key->hmacLengthBits()));
            return algorithm;
        }
        case AlgorithmFamily::Rsa: {
            auto public_exponent = createUint8ArrayCopy(global_object, scope, key->rsaPublicExponent());
            RETURN_IF_EXCEPTION(scope, {});
            // RSAES-PKCS1-v1_5 keys take no hash.
            const bool has_hash = key->algorithm() != CryptoKeyAlgorithm::RsaEsPkcs1V15;
            auto* algorithm = createNamedObject(global_object, vm, spec.name, has_hash ? 4 : 3);
            algorithm->putDirect(
                vm, JSC::Identifier::fromString(vm, "modulusLength"_s), JSC::jsNumber(key->rsaModulusBits()));
            algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "publicExponent"_s), public_exponent);
            if (has_hash) {
                algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "hash"_s),
                    createNamedObject(global_object, vm, hashSpec(key->hash()).name, 1));
            }
            return algorithm;
        }
        case AlgorithmFamily::Ec: {
            auto* algorithm = createNamedObject(global_object, vm, spec.name, 2);
            algorithm->putDirect(vm, JSC::Identifier::fromString(vm, "namedCurve"_s),
                JSC::jsString(vm, String(curveSpec(key->namedCurve()).name)));
            return algorithm;
        }
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    JSColloCryptoKey* requireKeyReceiver(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* key = dynamicDowncast<JSColloCryptoKey>(call_frame->thisValue());
        if (!key)
            JSC::throwTypeError(global_object, scope, "CryptoKey accessor called on incompatible receiver"_s);
        return key;
    }

} // namespace

// FIXME: Each read builds a new object, so `key.algorithm !== key.algorithm`. The Web Cryptography API (CryptoKey
// interface members) returns one cached object per key for `algorithm`, and likewise for `usages`, which
// `cryptoKeyGetUsages` also rebuilds on every read.
JSC_DEFINE_HOST_FUNCTION(cryptoKeyGetAlgorithm, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* key = requireKeyReceiver(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, JSC::JSValue::encode(createCryptoKeyAlgorithm(global_object, vm, scope, key)));
}

JSC_DEFINE_HOST_FUNCTION(cryptoKeyGetExtractable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* key = requireKeyReceiver(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(JSC::jsBoolean(key->extractable()));
}

JSC_DEFINE_HOST_FUNCTION(cryptoKeyGetType, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* key = requireKeyReceiver(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
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
    auto* key = requireKeyReceiver(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    auto* usages = createUsagesArray(global_object, scope, key->usages());
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(usages);
}

// One host function serves every refusing interface constructor; the message names the callee.
JSC_DEFINE_HOST_FUNCTION(refuseInterfaceConstruction, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* callee = dynamicDowncast<JSC::JSFunction>(call_frame->jsCallee());
    String name = callee ? callee->name(vm) : String("Interface"_s);
    return JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " is not constructable"_s));
}

JSC::JSFunction* createInterfaceConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, String(name), refuseInterfaceConstruction,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, refuseInterfaceConstruction, nullptr);
    RELEASE_ASSERT(constructor);
    return constructor;
}

}
