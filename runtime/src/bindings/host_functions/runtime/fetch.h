// Declares the hand-off of an outgoing fetch to the worker's Zig runtime, which fetch.cpp defines, and its
// cancellation. Both run on the VM thread.

#pragma once

#include "host_functions/runtime/bridge.h"
#include "host_functions/server/fetch/headers.h"

#include <wtf/Vector.h>

namespace Collo::HostFunctions::Runtime {

// The fields of a Request that scheduleFetch sends, copied out so that no JavaScript value crosses the ABI. `flags` is
// ColloFetchInit's, whose low two bits hold the redirect mode.
struct FetchRequestSnapshot {
    WTF::String url;
    WTF::String method;
    WTF::Vector<uint8_t> body;
    WTF::Vector<ColloHeaderPair> headers;
    uint32_t flags { 0 };
};

// On success `encoded` is the fetch's promise and `fetch_id` names the fetch for cancelFetch, or is 0 when the runtime
// refused the fetch and already rejected the promise, which then has nothing to cancel and gets no abort wiring. On
// failure an exception is pending in the scope.
struct ScheduledFetch {
    JSC::EncodedJSValue encoded {};
    uint64_t fetch_id { 0 };
    bool ok { false };
};

// Throws a QuotaExceededError DOMException for a request over one of the WebApiFetchRequest limits in
// webapi/limits.h, and an Error or OutOfMemoryError when the request cannot be encoded or scheduled.
ScheduledFetch scheduleFetch(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ActiveRequestRuntime&, FetchRequestSnapshot&&);
// Best effort: does nothing for fetch id 0, a global that is not a Collo global, or a VM without a host runtime. A
// non-empty `reason` reaches the runtime as a value handle, or is dropped when the handle cannot be made.
void cancelFetch(JSC::JSGlobalObject*, uint64_t fetch_id, JSC::JSValue reason = {});

} // namespace Collo::HostFunctions::Runtime
