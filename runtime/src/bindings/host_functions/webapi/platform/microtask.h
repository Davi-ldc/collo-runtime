// Declares the `queueMicrotask` global and its installer, which the host function registry (`globals.def`) calls
// once per realm, on the VM thread, when the VM installs Web APIs.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

JSC::EncodedJSValue queueMicrotask(JSC::JSGlobalObject*, JSC::CallFrame*);
void installWebApiMicrotask(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
