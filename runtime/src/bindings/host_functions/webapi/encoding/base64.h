// Declares atob and btoa, which the host function registry (`globals.def`) installs on the global object. They run on
// the VM thread; `base64.cpp` says how they fail.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

JSC::EncodedJSValue atob(JSC::JSGlobalObject*, JSC::CallFrame*);
JSC::EncodedJSValue btoa(JSC::JSGlobalObject*, JSC::CallFrame*);

} // namespace Collo::HostFunctions
