// The `fetch` host function, which globals.def installs as a global; fetch.cpp defines it.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

JSC::EncodedJSValue fetch(JSC::JSGlobalObject*, JSC::CallFrame*);

} // namespace Collo::HostFunctions
