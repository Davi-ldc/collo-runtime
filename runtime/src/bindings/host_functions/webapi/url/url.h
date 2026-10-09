// Declares the installer of the URL and URLSearchParams globals, and the URLSearchParams factory that the request
// object uses for its query. Both run on the VM thread; `url.cpp` and `search_params.cpp` define them.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

// Returns a new URLSearchParams with no associated URL, parsed from `value` as application/x-www-form-urlencoded
// after dropping one leading '?'. `global_object` must be a `Collo::GlobalObject` whose URL API is installed. It
// never throws and applies no pair cap: `value` must come from a URL the runtime already accepted, as
// `createURLSearchParamsFromSearch` in `search_params.cpp` explains.
JSC::JSObject* createURLSearchParamsFromString(JSC::JSGlobalObject*, WTF::String value);
// Installs `URL` and `URLSearchParams` and caches their constructors, prototypes and structures on the realm. The host
// function registry (`globals.def`) calls it once per realm.
void installWebApiURL(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
