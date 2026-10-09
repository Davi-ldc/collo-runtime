// Host functions for the `SubtleCrypto` methods, which `installWebApiCrypto` puts on `SubtleCrypto.prototype`. Each
// returns a promise, and a bad argument rejects it rather than throwing.

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
