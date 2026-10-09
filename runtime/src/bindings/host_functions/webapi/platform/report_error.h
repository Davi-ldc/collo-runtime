// Declares the `reportError` global, which the host function registry (`globals.def`) defines on the VM thread.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

JSC::EncodedJSValue reportError(JSC::JSGlobalObject*, JSC::CallFrame*);

} // namespace Collo::HostFunctions
