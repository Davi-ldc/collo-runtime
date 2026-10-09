// `SubtleCrypto.digest`. The input is copied on the VM thread; an input of at most `inlineDigestByteLimit` bytes is
// hashed inline before the method returns, and a larger one on the crypto pool.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/subtle/methods.h"

#include "host_functions/support.h"
#include "host_functions/webapi/crypto/jobs.h"
#include "host_functions/webapi/crypto/key_io/key_io.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/ops/asymmetric.h"
#include "host_functions/webapi/crypto/ops/kdf.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "host_functions/webapi/crypto/types.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSObject.h>
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <wtf/Vector.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <optional>
#include <span>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;
using namespace Collo::HostFunctions::WebCrypto;
using namespace Collo::JscSupport;

JSC_DEFINE_HOST_FUNCTION(subtleDigest, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!dynamicDowncast<JSColloSubtleCrypto>(call_frame->thisValue()))
        return rejectedTypeError(global_object, "Can only call SubtleCrypto.digest on instances of SubtleCrypto"_s);
    if (call_frame->argumentCount() < 2)
        return rejectedTypeError(global_object, "Not enough arguments"_s);

    JSC::JSValue error;
    const HashSpec* hash = nullptr;
    if (!normalizeHashAlgorithm(global_object, scope, call_frame->argument(0), hash, error))
        return rejectedPromise(global_object, error);

    WTF::Vector<uint8_t> data;
    if (!copyBufferSource(global_object, scope, call_frame->argument(1), data, error))
        return rejectedPromise(global_object, error);

    auto context = createCryptoAsyncContext(global_object, scope);
    if (!context.ok)
        return context.error;

    WebCryptoHash hash_id = hash->id;
    const CryptoJobCost cost
        = data.size() <= inlineDigestByteLimit ? CryptoJobCost::InlinePreferred : CryptoJobCost::Heavy;
    auto job = std::unique_ptr<CryptoJob>(new (std::nothrow) BytesCryptoJob(
        context.value.owner, context.value.deferred,
        [hash_id, data = WTF::move(data)](WTF::Vector<uint8_t>& out) mutable {
            const auto& spec = hashSpec(hash_id);
            return digestBytes(spec, data.span(), out);
        },
        cost));
    return enqueueCryptoJobPromise(global_object, scope, context.value, WTF::move(job));
}

} // namespace Collo::HostFunctions
