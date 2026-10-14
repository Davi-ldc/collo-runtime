// `SubtleCrypto.digest`, hashed on the VM thread over the borrowed input in slices its time guard admits (budget.h).

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/methods.h"

#include "host_functions/webapi/crypto/budget.h"
#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "host_functions/webapi/crypto/subtle/steps.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>

#include <array>

namespace Collo::HostFunctions {

using namespace Collo::HostFunctions::WebCrypto;
using namespace Collo::JscSupport;

JSC_DEFINE_HOST_FUNCTION(subtleDigest, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return promiseFromThrowingSteps(global_object, [&]() -> JSC::JSValue {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        checkSubtleCall(global_object, scope, call_frame, "digest"_s, 2);
        RETURN_IF_EXCEPTION(scope, {});
        requireBufferSource(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        auto* hash = normalizeHashAlgorithm(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});

        auto data = borrowBufferSource(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        TimeGuard guard(hostRuntimeOf(global_object));
        if (!requireStartFits(global_object, scope, guard, digestWorstCaseNs(hash->id, data->size())))
            return {};
        std::array<uint8_t, EVP_MAX_MD_SIZE> digest;
        if (!digestBytes(*hash, *data, digest, guard)) {
            throwOperationFailed(global_object, scope, guard);
            return {};
        }
        RELEASE_AND_RETURN(scope,
            createArrayBufferCopy(
                global_object, scope, std::span<const uint8_t> { digest.data(), hash->digest_bytes }));
    });
}

} // namespace Collo::HostFunctions
