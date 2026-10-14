// `SubtleCrypto.importKey`, `exportKey`, `wrapKey` and `unwrapKey`, on the VM thread. Format parsing and serialization
// live in `key_io/`; wrapKey and unwrapKey encrypt and decrypt through the shared cipher entry (steps.h). unwrapKey
// imports the decrypted bytes through the same import core as importKey, so both accept exactly the same keys.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/methods.h"

#include "host_functions/webapi/crypto/key_io/key_io.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/subtle/steps.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>

namespace Collo::HostFunctions {

using namespace Collo::HostFunctions::WebCrypto;
using namespace Collo::JscSupport;

JSC_DEFINE_HOST_FUNCTION(subtleImportKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(global_object, [&]() -> JSC::JSValue {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        checkSubtleCall(global_object, scope, call_frame, "importKey"_s, 5);
        RETURN_IF_EXCEPTION(scope, {});
        auto format = parseKeyFormat(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        // keyData is a (BufferSource or JsonWebKey) union: a BufferSource for the byte formats, a dictionary for "jwk".
        JSC::JSValue key_data = call_frame->argument(1);
        std::optional<JwkRecord> jwk;
        std::optional<SecretBytes> bytes;
        if (*format == KeyFormat::Jwk) {
            if (isBufferSource(key_data)) {
                JSC::throwTypeError(global_object, scope, "JWK key data must be a JsonWebKey"_s);
                return {};
            }
            jwk = readJwkRecord(global_object, scope, key_data);
        } else
            bytes = copySecretBufferSource(global_object, scope, key_data);
        RETURN_IF_EXCEPTION(scope, {});
        const bool extractable = call_frame->argument(3).toBoolean(global_object);
        auto usages = parseKeyUsages(global_object, scope, call_frame->argument(4));
        RETURN_IF_EXCEPTION(scope, {});
        auto algorithm = normalizeAlgorithm(global_object, scope, Operation::ImportKey, call_frame->argument(2));
        RETURN_IF_EXCEPTION(scope, {});

        ImportRequest request { *format, *algorithm, extractable, *usages };
        auto* key = jwk ? importKeyFromJwk(global_object, scope, request, *jwk)
                        : importKeyFromBytes(global_object, scope, request, WTF::move(*bytes));
        RETURN_IF_EXCEPTION(scope, {});
        return key;
    });
}

JSC_DEFINE_HOST_FUNCTION(subtleExportKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(global_object, [&]() -> JSC::JSValue {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        checkSubtleCall(global_object, scope, call_frame, "exportKey"_s, 2);
        RETURN_IF_EXCEPTION(scope, {});
        auto format = parseKeyFormat(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        auto* key = requireCryptoKey(global_object, scope, call_frame->argument(1), "Expected a CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        checkExportable(global_object, scope, key);
        RETURN_IF_EXCEPTION(scope, {});
        if (*format == KeyFormat::Jwk)
            RELEASE_AND_RETURN(scope, exportJwk(global_object, scope, key));
        auto bytes = exportKeyBytes(global_object, scope, *format, key);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, createArrayBufferCopy(global_object, scope, bytes->span()));
    });
}

JSC_DEFINE_HOST_FUNCTION(subtleWrapKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(global_object, [&]() -> JSC::JSValue {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        checkSubtleCall(global_object, scope, call_frame, "wrapKey"_s, 4);
        RETURN_IF_EXCEPTION(scope, {});
        auto format = parseKeyFormat(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        auto* key = requireCryptoKey(global_object, scope, call_frame->argument(1), "Expected a CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto* wrapping_key
            = requireCryptoKey(global_object, scope, call_frame->argument(2), "Expected a wrapping CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto algorithm = normalizeAlgorithm(global_object, scope, Operation::WrapKey, call_frame->argument(3));
        RETURN_IF_EXCEPTION(scope, {});
        checkKey(global_object, scope, wrapping_key, algorithm->id, CryptoKeyUsageWrapKey);
        RETURN_IF_EXCEPTION(scope, {});
        checkExportable(global_object, scope, key);
        RETURN_IF_EXCEPTION(scope, {});

        auto exported = *format == KeyFormat::Jwk ? exportJwkText(global_object, scope, key)
                                                  : exportKeyBytes(global_object, scope, *format, key);
        RETURN_IF_EXCEPTION(scope, {});
        auto wrapped
            = runCipher(global_object, scope, CipherDirection::Encrypt, *algorithm, wrapping_key, exported->span());
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, createArrayBufferCopy(global_object, scope, wrapped->span()));
    });
}

JSC_DEFINE_HOST_FUNCTION(subtleUnwrapKey, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(global_object, [&]() -> JSC::JSValue {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        checkSubtleCall(global_object, scope, call_frame, "unwrapKey"_s, 7);
        RETURN_IF_EXCEPTION(scope, {});
        auto format = parseKeyFormat(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        // A copy: both normalizations below run getters, which could detach a borrowed buffer.
        auto wrapped = copyBufferSource(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        auto* unwrapping_key
            = requireCryptoKey(global_object, scope, call_frame->argument(2), "Expected an unwrapping CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        const bool extractable = call_frame->argument(5).toBoolean(global_object);
        auto usages = parseKeyUsages(global_object, scope, call_frame->argument(6));
        RETURN_IF_EXCEPTION(scope, {});
        auto algorithm = normalizeAlgorithm(global_object, scope, Operation::UnwrapKey, call_frame->argument(3));
        RETURN_IF_EXCEPTION(scope, {});
        auto import_algorithm = normalizeAlgorithm(global_object, scope, Operation::ImportKey, call_frame->argument(4));
        RETURN_IF_EXCEPTION(scope, {});
        checkKey(global_object, scope, unwrapping_key, algorithm->id, CryptoKeyUsageUnwrapKey);
        RETURN_IF_EXCEPTION(scope, {});

        auto plaintext
            = runCipher(global_object, scope, CipherDirection::Decrypt, *algorithm, unwrapping_key, wrapped->span());
        RETURN_IF_EXCEPTION(scope, {});
        ImportRequest request { *format, *import_algorithm, extractable, *usages };
        if (*format != KeyFormat::Jwk) {
            auto* key = importKeyFromBytes(global_object, scope, request, WTF::move(*plaintext));
            RETURN_IF_EXCEPTION(scope, {});
            return key;
        }
        auto jwk = parseJwkRecord(global_object, scope, plaintext->span());
        RETURN_IF_EXCEPTION(scope, {});
        auto* key = importKeyFromJwk(global_object, scope, request, *jwk);
        RETURN_IF_EXCEPTION(scope, {});
        return key;
    });
}

} // namespace Collo::HostFunctions
