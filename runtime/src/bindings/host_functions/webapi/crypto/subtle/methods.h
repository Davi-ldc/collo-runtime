// Host functions for the `SubtleCrypto` methods, which `installWebApiCrypto` puts on `SubtleCrypto.prototype`. Each
// runs its operation on the VM thread before it returns and gives back a promise already settled with the result; a
// step that throws rejects the promise instead (`promiseFromThrowingSteps` in js_support.h).

#pragma once

#include <JavaScriptCore/JSGlobalObject.h>

namespace Collo::HostFunctions {

JSC_DECLARE_HOST_FUNCTION(subtleDigest);
JSC_DECLARE_HOST_FUNCTION(subtleImportKey);
JSC_DECLARE_HOST_FUNCTION(subtleExportKey);
JSC_DECLARE_HOST_FUNCTION(subtleGenerateKey);
JSC_DECLARE_HOST_FUNCTION(subtleEncrypt);
JSC_DECLARE_HOST_FUNCTION(subtleDecrypt);
JSC_DECLARE_HOST_FUNCTION(subtleDeriveBits);
JSC_DECLARE_HOST_FUNCTION(subtleDeriveKey);
JSC_DECLARE_HOST_FUNCTION(subtleWrapKey);
JSC_DECLARE_HOST_FUNCTION(subtleUnwrapKey);
JSC_DECLARE_HOST_FUNCTION(subtleSign);
JSC_DECLARE_HOST_FUNCTION(subtleVerify);

} // namespace Collo::HostFunctions
