// `SubtleCrypto.encrypt` and `decrypt`: one method body for both, run through the shared cipher entry (steps.h) on the
// VM thread. The registration table (algorithms.h) decides which algorithms each accepts; AES-KW only wraps keys, so
// both reject it with NotSupportedError.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/methods.h"

#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/subtle/steps.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>

namespace Collo::HostFunctions {

using namespace Collo::HostFunctions::WebCrypto;
using namespace Collo::JscSupport;

namespace {

    JSC::JSValue cipherMethod(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame, CipherDirection direction)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        const bool encrypt = direction == CipherDirection::Encrypt;
        checkSubtleCall(global_object, scope, call_frame, encrypt ? "encrypt"_s : "decrypt"_s, 3);
        RETURN_IF_EXCEPTION(scope, {});
        auto* key = requireCryptoKey(global_object, scope, call_frame->argument(1), "Expected a CryptoKey"_s);
        RETURN_IF_EXCEPTION(scope, {});
        requireBufferSource(global_object, scope, call_frame->argument(2));
        RETURN_IF_EXCEPTION(scope, {});
        auto algorithm = normalizeAlgorithm(
            global_object, scope, encrypt ? Operation::Encrypt : Operation::Decrypt, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        checkKey(global_object, scope, key, algorithm->id, encrypt ? CryptoKeyUsageEncrypt : CryptoKeyUsageDecrypt);
        RETURN_IF_EXCEPTION(scope, {});

        auto data = borrowBufferSource(global_object, scope, call_frame->argument(2));
        RETURN_IF_EXCEPTION(scope, {});
        auto result = runCipher(global_object, scope, direction, *algorithm, key, *data);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, createArrayBufferCopy(global_object, scope, result->span()));
    }

} // namespace

JSC_DEFINE_HOST_FUNCTION(subtleEncrypt, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(
        global_object, [&] { return cipherMethod(global_object, call_frame, CipherDirection::Encrypt); });
}

JSC_DEFINE_HOST_FUNCTION(subtleDecrypt, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(
        global_object, [&] { return cipherMethod(global_object, call_frame, CipherDirection::Decrypt); });
}

} // namespace Collo::HostFunctions
