// Declares the HTML timer globals (setTimeout, setInterval, clearTimeout, clearInterval) and Node's setImmediate and
// clearImmediate, which the host function registry (`globals.def`) defines on the VM thread.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

JSC::EncodedJSValue setTimeout(JSC::JSGlobalObject*, JSC::CallFrame*);
JSC::EncodedJSValue setInterval(JSC::JSGlobalObject*, JSC::CallFrame*);
JSC::EncodedJSValue setImmediate(JSC::JSGlobalObject*, JSC::CallFrame*);
JSC::EncodedJSValue clearTimeout(JSC::JSGlobalObject*, JSC::CallFrame*);
JSC::EncodedJSValue clearInterval(JSC::JSGlobalObject*, JSC::CallFrame*);
JSC::EncodedJSValue clearImmediate(JSC::JSGlobalObject*, JSC::CallFrame*);

} // namespace Collo::HostFunctions
