// Installs the Web Cryptography API on a global object: the `crypto` instance with its `subtle` member, and the
// `Crypto`, `SubtleCrypto` and `CryptoKey` interfaces, whose constructors throw on every call. It runs at most once
// per realm, on the VM thread, when the VM installs Web APIs; a worker's VM and main realm are created in the zygote,
// so every worker inherits the main realm's objects from the zygote's heap. The CryptoKey structure is cached on the
// global object (`cacheCryptoApi`), where the key factories in `keys.cpp` read it, so this installer must run before
// any key is created.

#include "host_functions/webapi/crypto/crypto.h"

#include "host_functions/support.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/subtle/methods.h"
#include "host_functions/webapi/crypto/sync/methods.h"

#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {
namespace {

    using WTF::String;
    using namespace Collo::HostFunctions::WebCrypto;

} // namespace

void installWebApiCrypto(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto* subtle_prototype = JSC::constructEmptyObject(global_object);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);
    putWebApiFunction(global_object, subtle_prototype, vm, "encrypt"_s, 3, subtleEncrypt, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "decrypt"_s, 3, subtleDecrypt, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "sign"_s, 3, subtleSign, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "verify"_s, 4, subtleVerify, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "digest"_s, 2, subtleDigest, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "generateKey"_s, 3, subtleGenerateKey, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "deriveKey"_s, 5, subtleDeriveKey, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "deriveBits"_s, 3, subtleDeriveBits, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "importKey"_s, 5, subtleImportKey, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "exportKey"_s, 2, subtleExportKey, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "wrapKey"_s, 4, subtleWrapKey, enumerableFunction);
    putWebApiFunction(global_object, subtle_prototype, vm, "unwrapKey"_s, 7, subtleUnwrapKey, enumerableFunction);
    subtle_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("SubtleCrypto"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* subtle_constructor = createSubtleCryptoConstructor(global_object, vm);
    subtle_constructor->putDirect(vm, vm.propertyNames->prototype, subtle_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    subtle_prototype->putDirect(
        vm, vm.propertyNames->constructor, subtle_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    auto* subtle_structure = JSColloSubtleCrypto::createStructure(vm, global_object, subtle_prototype);
    auto* subtle = JSColloSubtleCrypto::create(vm, subtle_structure);

    auto* key_prototype = JSC::constructEmptyObject(global_object);
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    putWebApiAccessor(
        global_object, key_prototype, vm, "algorithm"_s, cryptoKeyGetAlgorithm, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, key_prototype, vm, "extractable"_s, cryptoKeyGetExtractable, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, key_prototype, vm, "type"_s, cryptoKeyGetType, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, key_prototype, vm, "usages"_s, cryptoKeyGetUsages, nullptr, enumerableAccessor);
    key_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("CryptoKey"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* key_constructor = createCryptoKeyConstructor(global_object, vm);
    key_constructor->putDirect(vm, vm.propertyNames->prototype, key_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    key_prototype->putDirect(
        vm, vm.propertyNames->constructor, key_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    auto* key_structure = JSColloCryptoKey::createStructure(vm, global_object, key_prototype);
    global_object->cacheCryptoApi(
        subtle_constructor, subtle_prototype, subtle_structure, key_constructor, key_prototype, key_structure);

    auto* prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
    putWebApiFunction(global_object, prototype, vm, "getRandomValues"_s, 1, cryptoGetRandomValues, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "randomUUID"_s, 0, cryptoRandomUUID, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "timingSafeEqual"_s, 2, cryptoTimingSafeEqual, enumerableFunction);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("Crypto"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = createCryptoConstructor(global_object, vm);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* structure = JSColloCrypto::createStructure(vm, global_object, prototype);
    auto* crypto = JSColloCrypto::create(vm, structure);
    // FIXME: WebIDL maps `readonly attribute SubtleCrypto subtle` to an enumerable, configurable getter on
    // `Crypto.prototype`; this installs a non-writable, non-configurable data property on the instance instead.
    crypto->putDirect(vm, JSC::Identifier::fromString(vm, "subtle"_s), subtle,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete);

    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "Crypto"_s), constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "SubtleCrypto"_s), subtle_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "CryptoKey"_s), key_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "crypto"_s), crypto,
        static_cast<unsigned>(JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "Crypto"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "SubtleCrypto"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "CryptoKey"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "crypto"_s)));
}

} // namespace Collo::HostFunctions
