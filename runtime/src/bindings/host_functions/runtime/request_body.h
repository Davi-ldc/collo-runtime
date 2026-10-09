// Declares the reads of an incoming request's body, which request_body.cpp passes to the worker's Zig runtime. They
// run on the VM thread. Each returns a promise the runtime settles with the whole body as text, parsed JSON, an
// ArrayBuffer, a Uint8Array, a Blob of `type`, or FormData parsed by `content_type`. Outside a turn of the request
// that `token` names, the promise is rejected with a TypeError before anything crosses the ABI; without a host runtime
// the call throws an Error.

#pragma once

#include "host_functions/support.h"

#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

JSC::EncodedJSValue requestTextForIdentity(JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloRequestIdentity& token);
JSC::EncodedJSValue requestJsonForIdentity(JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloRequestIdentity& token);
JSC::EncodedJSValue requestArrayBufferForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloRequestIdentity& token);
JSC::EncodedJSValue requestBytesForIdentity(JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloRequestIdentity& token);
JSC::EncodedJSValue requestBlobForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloRequestIdentity& token, WTF::String type);
JSC::EncodedJSValue requestFormDataForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloRequestIdentity& token, WTF::String content_type);

} // namespace Collo::HostFunctions
