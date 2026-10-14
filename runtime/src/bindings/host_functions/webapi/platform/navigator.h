// Declares the installer of the `navigator` global, which runs on the VM thread; `navigator.cpp` says what the object
// holds.

#pragma once

#include "jsc/runtime/state.h"

namespace Collo::HostFunctions {

// Defines `navigator` on a realm's global object. The host function registry (`globals.def`) calls it once per realm
// whose VM installs Web APIs.
void installWebApiNavigator(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
