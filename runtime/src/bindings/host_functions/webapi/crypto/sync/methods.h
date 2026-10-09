// Host functions for the synchronous `Crypto` methods, which `installWebApiCrypto` puts on `Crypto.prototype`.

#pragma once

#include <JavaScriptCore/JSGlobalObject.h>

namespace Collo::HostFunctions::WebCrypto {

JSC_DECLARE_HOST_FUNCTION(cryptoGetRandomValues);
JSC_DECLARE_HOST_FUNCTION(cryptoRandomUUID);
JSC_DECLARE_HOST_FUNCTION(cryptoTimingSafeEqual);

} // namespace Collo::HostFunctions::WebCrypto
