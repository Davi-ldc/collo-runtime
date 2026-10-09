// The Request class's entry points outside request.cpp: the global fetch() schedules its outbound fetch through a
// Request built here, and host function installation installs the class. VM thread only. Every JSGlobalObject
// parameter must be a Collo::GlobalObject.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions::Runtime {
struct ActiveRequestRuntime;
}

namespace Collo::HostFunctions {

// Builds a Request from `input` and `init` as the Request constructor does and schedules it as an outbound fetch of
// the execution context `runtime` describes, a request turn or the boot context the worker installs for module
// evaluation, returning the fetch promise. A Request option the outbound fetch does not implement, or a signal that is
// already aborted, yields a rejected promise. Errors from building the Request or from reading its headers and body
// throw into `scope`. When the Request's signal controls the fetch, aborting the signal cancels the fetch.
// FIXME: The Fetch Standard has fetch() reject its promise with those errors instead of throwing.
JSC::EncodedJSValue scheduleFetchFromRequest(JSC::JSGlobalObject*, JSC::ThrowScope&,
    const Runtime::ActiveRequestRuntime&, JSC::JSValue input, JSC::JSValue init);
// Installs the Request constructor and prototype on the global object and stores them with the Request structure in
// the realm's Web API cache. Host function installation calls it once per realm.
void installServerRequest(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
